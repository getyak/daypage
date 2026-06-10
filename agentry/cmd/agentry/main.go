// Command agentry is the CLI entry point that wires the four seams (Provider,
// Tool, Transport, Session) together into a runnable agent runtime + callable
// platform + web-fused browser agent + TUI workbench (see DESIGN.md).
//
// It is intentionally thin: every command resolves configuration, builds an
// *agent.Engine via buildEngine, and hands that engine to the relevant
// subsystem (the one-shot loop, a transport, or the TUI). No agent logic lives
// here — main only assembles parts that already exist and compile.
//
// Command surface (DESIGN §13):
//
//	agentry run "<prompt>"   one-shot; prints the final answer (pipeable)
//	agentry chat             interactive TUI
//	agentry serve            run as a platform: --http[=addr] | --stdio | --mcp
//	agentry tools list       print the registered tools
//	agentry session ls       list persisted sessions (best-effort)
//	agentry session show <id> print a persisted session's transcript
//	agentry mcp add <cmd...> register/test-connect an MCP server (best-effort)
//	agentry version          print the version string
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/kubbot/agentry/internal/config"
	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/policy"
	"github.com/kubbot/agentry/internal/core/provider"
	"github.com/kubbot/agentry/internal/core/provider/anthropic"
	"github.com/kubbot/agentry/internal/core/provider/mock"
	"github.com/kubbot/agentry/internal/core/provider/openaicompat"
	"github.com/kubbot/agentry/internal/core/provider/retry"
	"github.com/kubbot/agentry/internal/core/session"
	"github.com/kubbot/agentry/internal/core/tool"
	"github.com/kubbot/agentry/internal/tools/builtin"
	"github.com/kubbot/agentry/internal/tools/mcp"
	"github.com/kubbot/agentry/internal/tools/web"
	"github.com/kubbot/agentry/internal/tools/web/browser"
	httptransport "github.com/kubbot/agentry/internal/transport/http"
	"github.com/kubbot/agentry/internal/transport/mcpserver"
	"github.com/kubbot/agentry/internal/transport/stdio"
	"github.com/kubbot/agentry/internal/ui/tui"
)

// version is the binary's reported version. Overridable at build time via
// -ldflags "-X main.version=<v>" so releases can stamp a real value.
var version = "0.1.0-dev"

// globalFlags are the provider/model overrides shared by commands that build an
// engine. They sit above config-file and env values (DESIGN §12 precedence:
// defaults -> file -> env -> flags), and are applied inside buildEngine.
type globalFlags struct {
	provider string // overrides cfg.DefaultProvider (e.g. "claude", "openai", "dashscope")
	model    string // overrides the resolved model id
}

// gf holds the parsed global flags for the current invocation. Cobra binds the
// persistent flags onto it before any RunE executes.
var gf globalFlags

func main() {
	if err := newRootCmd().Execute(); err != nil {
		// Cobra already prints the error for RunE failures; we add a non-zero exit
		// so the binary is usable in scripts and pipelines.
		os.Exit(1)
	}
}

// newRootCmd assembles the cobra command tree.
func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "agentry",
		Short: "Agentry — an agent runtime, callable platform, web-fused browser agent, and TUI",
		Long: "Agentry is a single Go binary that is simultaneously an agent runtime " +
			"(reason→act→observe loop with tool use), a platform exposed over stdio/HTTP/MCP, " +
			"a web-fused agent with browser automation, and an interactive TUI workbench.",
		SilenceUsage:  true, // don't dump usage on a runtime (RunE) error
		SilenceErrors: false,
	}

	// Persistent flags are available to every subcommand that builds an engine.
	root.PersistentFlags().StringVar(&gf.provider, "provider", "",
		"provider to use (claude | openai | dashscope); overrides config/env")
	root.PersistentFlags().StringVar(&gf.model, "model", "",
		"model id to use; overrides the provider's default")

	root.AddCommand(
		newRunCmd(),
		newChatCmd(),
		newServeCmd(),
		newToolsCmd(),
		newSessionCmd(),
		newMCPCmd(),
		newVersionCmd(),
	)
	return root
}

// ---------------------------------------------------------------------------
// buildEngine — the central wiring helper
// ---------------------------------------------------------------------------

// buildEngine constructs a fully wired *agent.Engine from configuration plus the
// global provider/model flags. It:
//
//  1. selects the provider entry (flag > config DefaultProvider);
//  2. resolves the model (flag > global config model > provider model);
//  3. resolves the API key from the provider's configured env var;
//  4. instantiates the concrete adapter (anthropic vs openaicompat), or falls
//     back to the deterministic mock when no key is set so the binary is always
//     runnable for smoke tests (a note is printed to stderr);
//  5. builds a tool.Registry seeded with builtin + web + browser tools; and
//  6. returns agent.New(provider, registry, policy.Default(), model).
//
// The chosen model is returned alongside the engine so callers can seed a
// session's Model field with the same value the engine will use.
func buildEngine(cfg *config.Config) (*agent.Engine, string, error) {
	if cfg == nil {
		return nil, "", errors.New("buildEngine: nil config")
	}

	// 1. Resolve the provider name: explicit flag wins, else config default.
	providerName := gf.provider
	if providerName == "" {
		providerName = cfg.DefaultProvider
	}
	pc, ok := cfg.ResolveProvider(providerName)
	if !ok {
		return nil, "", fmt.Errorf("unknown provider %q (configure it in %s or pass --provider)",
			providerName, filepath.Join(config.ConfigDir(), "config.json"))
	}

	// 2. Resolve the model: flag overrides everything, else config/provider chain.
	model := gf.model
	if model == "" {
		model = cfg.ResolveModel(providerName)
	}

	// 3. Resolve the API key from the provider's configured env var (never the
	// config file itself, per DESIGN §12).
	apiKey := cfg.ResolveAPIKey(providerName)

	// 4. Instantiate the provider adapter, or fall back to mock when no key. The
	// resolved retry policy (config/AGENTRY_RETRY_*) governs transient-failure
	// backoff for the openai-compatible adapter.
	prov, model := selectProvider(pc, providerName, model, apiKey, cfg.RetryPolicy())

	// 4b. Apply the operator-tunable web tool bounds + retry policy so
	// web.fetch/web.extract/web.search honor config/AGENTRY_WEB_*/AGENTRY_RETRY_*
	// (timeout, redirect cap, body ceiling, and transient-failure backoff with
	// connection reuse). A no-op when nothing is configured (defaults preserved).
	configureWebTools(cfg)

	// 5. Build the tool registry: builtin + web + browser, all mediated by policy.
	reg := buildRegistry()

	// 6. Assemble the engine with the default safety policy.
	eng := agent.New(prov, reg, policy.Default(), model)
	return eng, model, nil
}

// selectProvider maps a resolved ProviderConfig to a concrete provider.Provider.
// When apiKey is empty it returns the deterministic mock provider (printing a
// one-line note to stderr) so a bare invocation still runs end-to-end for smoke
// tests rather than failing on a missing credential. It returns the provider and
// the (possibly substituted) model id. rp is the resolved transient-failure
// retry policy applied to the openai-compatible adapter (the anthropic adapter
// carries its own default).
func selectProvider(pc config.ProviderConfig, providerName, model, apiKey string, rp retry.Policy) (provider.Provider, string) {
	if strings.TrimSpace(apiKey) == "" {
		fmt.Fprintf(os.Stderr,
			"agentry: no API key for provider %q (set %s); using the offline mock provider.\n",
			providerName, envHint(pc))
		return mock.New(), model
	}

	switch pc.Kind {
	case config.KindAnthropic:
		// baseURL is optional for Anthropic (the adapter defaults it).
		return anthropic.New(apiKey, pc.BaseURL, model), model
	case config.KindOpenAICompat:
		return openaicompat.New(apiKey, pc.BaseURL, model, openaicompat.WithRetryPolicy(rp)), model
	default:
		// An unrecognized kind is a config error, but rather than aborting the
		// whole CLI we degrade to the mock so the binary stays usable and the
		// problem is visible.
		fmt.Fprintf(os.Stderr,
			"agentry: provider %q has unknown kind %q; using the offline mock provider.\n",
			providerName, pc.Kind)
		return mock.New(), model
	}
}

// envHint returns the env var name that should hold the provider's key, for a
// helpful "set X" message. Falls back to a generic phrase when unconfigured.
func envHint(pc config.ProviderConfig) string {
	if pc.APIKeyEnv != "" {
		return pc.APIKeyEnv
	}
	return "the provider's API key env var"
}

// configureWebTools pushes the resolved web-tool bounds and retry policy into
// the web package so web.fetch/web.extract/web.search honor the operator's
// config/AGENTRY_* settings (timeout, redirect cap, body ceiling, and
// transient-failure backoff). Zero/unset fields leave the built-in defaults
// intact, so an unconfigured deployment behaves exactly as before.
func configureWebTools(cfg *config.Config) {
	wc := web.Config{Retry: cfg.RetryPolicy()}
	if cfg.Web.TimeoutMs > 0 {
		wc.RequestTimeout = time.Duration(cfg.Web.TimeoutMs) * time.Millisecond
	}
	if cfg.Web.MaxRedirects > 0 {
		wc.MaxRedirects = cfg.Web.MaxRedirects
	}
	if cfg.Web.MaxBytes > 0 {
		wc.HardMaxBytes = int64(cfg.Web.MaxBytes)
	}
	web.Configure(wc)
}

// buildRegistry creates a registry and registers every locally available tool
// family: builtin (fs/shell), web (fetch/extract/search), and browser
// (navigate/read/click/type/screenshot). Registration uses MustRegister: the
// tool names are static and collision-free, so a duplicate would be a
// programmer error worth failing loudly at startup.
func buildRegistry() *tool.Registry {
	reg := tool.NewRegistry()
	for _, t := range builtin.All() {
		reg.MustRegister(t)
	}
	for _, t := range web.All() {
		reg.MustRegister(t)
	}
	for _, t := range browser.All() {
		reg.MustRegister(t)
	}
	return reg
}

// loadConfig is a thin wrapper that surfaces a clear error for a malformed
// config file (a missing file is not an error; Load handles that).
func loadConfig() (*config.Config, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}
	return cfg, nil
}

// signalContext returns a context cancelled on SIGINT/SIGTERM so long-running
// commands (serve, chat) unwind cleanly on Ctrl+C. The returned stop func should
// be deferred to release the signal handler.
func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}

// sessionsDir is the directory holding persisted session logs:
// <AGENTRY_HOME>/sessions. Centralized so `run`, `session ls`, and
// `session show` all agree on the location.
func sessionsDir() string {
	return filepath.Join(config.ConfigDir(), "sessions")
}

// sessionStore returns the on-disk JSONL session store rooted at sessionsDir.
func sessionStore() *session.JSONLStore {
	return session.NewJSONLStore(sessionsDir())
}

// newSessionID builds a unique, filesystem-safe session id from a prefix plus a
// timestamp, so concurrent or repeated runs never overwrite each other's logs.
// The format sorts chronologically (e.g. "run-20060102-150405.000000000").
func newSessionID(prefix string) string {
	return fmt.Sprintf("%s-%s", prefix, time.Now().Format("20060102-150405.000000000"))
}

// ---------------------------------------------------------------------------
// run — one-shot prompt, prints final text to stdout
// ---------------------------------------------------------------------------

func newRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run <prompt>",
		Short: "Run a single prompt to completion and print the final answer",
		Long: "Build an engine from configuration, run the reason→act→observe loop " +
			"once on the given prompt, and print only the final assistant text to " +
			"stdout (so it is pipeable). With no API key configured, the offline mock " +
			"provider is used so the command always runs.",
		Args: cobra.ArbitraryArgs, // allow multi-word prompts without quoting
		RunE: func(cmd *cobra.Command, args []string) error {
			prompt := strings.TrimSpace(strings.Join(args, " "))
			if prompt == "" {
				return errors.New("a prompt is required, e.g. agentry run \"summarize ./README.md\"")
			}

			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			eng, model, err := buildEngine(cfg)
			if err != nil {
				return err
			}

			// Cancel on Ctrl+C so a long run can be interrupted.
			ctx, stop := signalContext()
			defer stop()

			// Run on a fresh session seeded with the resolved model and the process
			// working directory so session-aware tools (fs.*, shell.exec) anchor
			// relative paths sensibly. Each run gets a unique id so its persisted
			// log never clobbers a previous one.
			sess := session.New(newSessionID("run"))
			sess.Model = model
			sess.Title = prompt
			if wd, werr := os.Getwd(); werr == nil {
				sess.Cwd = wd
			}

			text, runErr := eng.Run(ctx, sess, prompt)

			// Persist the session log (best-effort): a failure to save must not mask
			// the run's own result, so we only warn. This makes the run resumable and
			// visible to `agentry session ls|show` (DESIGN §4.4, §7).
			if err := sessionStore().Save(sess); err != nil {
				fmt.Fprintf(os.Stderr, "agentry: warning: could not persist session %s: %v\n", sess.ID, err)
			}

			// Print whatever final text we got even if the run errored partway, so a
			// truncated answer is still surfaced; then report the error via exit code.
			if strings.TrimSpace(text) != "" {
				fmt.Fprintln(cmd.OutOrStdout(), text)
			}
			if runErr != nil {
				return fmt.Errorf("run failed: %w", runErr)
			}
			return nil
		},
	}
}

// ---------------------------------------------------------------------------
// chat — interactive TUI
// ---------------------------------------------------------------------------

func newChatCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "chat",
		Short: "Open the interactive TUI workbench",
		Long: "Launch the Bubble Tea terminal workbench: a streaming transcript, an " +
			"input box, and tool-call cards. It is a client of the same engine the " +
			"transports expose.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			eng, _, err := buildEngine(cfg)
			if err != nil {
				return err
			}

			ctx, stop := signalContext()
			defer stop()

			return tui.Run(ctx, eng)
		},
	}
}

// ---------------------------------------------------------------------------
// serve — run as a platform over a chosen transport
// ---------------------------------------------------------------------------

func newServeCmd() *cobra.Command {
	var (
		httpFlag  bool
		stdioFlag bool
		mcpFlag   bool
		addr      string
	)

	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Run agentry as a platform (HTTP, stdio JSON-RPC, or MCP server)",
		Long: "Expose the engine over one transport so users, programs, and other " +
			"agents can drive it. Exactly one of --http, --stdio, or --mcp must be " +
			"chosen. --http also serves the embedded Web UI at /. The HTTP listen " +
			"address defaults to the config value (" + config.DefaultServeAddr +
			") and can be overridden with --addr.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			// Exactly one transport must be selected.
			chosen := 0
			for _, b := range []bool{httpFlag, stdioFlag, mcpFlag} {
				if b {
					chosen++
				}
			}
			if chosen == 0 {
				return errors.New("choose a transport: --http, --stdio, or --mcp")
			}
			if chosen > 1 {
				return errors.New("choose exactly one transport (--http, --stdio, or --mcp)")
			}

			cfg, err := loadConfig()
			if err != nil {
				return err
			}
			eng, _, err := buildEngine(cfg)
			if err != nil {
				return err
			}

			ctx, stop := signalContext()
			defer stop()

			switch {
			case httpFlag:
				listen := addr
				if listen == "" {
					listen = cfg.Serve.Addr
				}
				if listen == "" {
					listen = config.DefaultServeAddr
				}
				// stderr so stdout stays clean for any tooling that scrapes it.
				fmt.Fprintf(os.Stderr, "agentry: HTTP transport listening on %s (Web UI at http://%s/)\n", listen, listen)
				// Wire the on-disk session store so sessions created/driven over
				// HTTP persist and can be resumed across restarts (DESIGN §4.4),
				// the same JSONL store `run` and `session ls|show` already use.
				return httptransport.ServeWithStore(ctx, eng, listen, sessionStore())
			case stdioFlag:
				fmt.Fprintln(os.Stderr, "agentry: stdio JSON-RPC transport ready on stdin/stdout")
				return stdio.ServeWithStore(ctx, eng, sessionStore())
			case mcpFlag:
				fmt.Fprintln(os.Stderr, "agentry: MCP server ready on stdin/stdout")
				return mcpserver.Serve(ctx, eng)
			}
			return nil // unreachable: guarded above
		},
	}

	cmd.Flags().BoolVar(&httpFlag, "http", false, "serve REST + SSE over HTTP and the embedded Web UI")
	cmd.Flags().BoolVar(&stdioFlag, "stdio", false, "serve newline-delimited JSON-RPC 2.0 over stdin/stdout")
	cmd.Flags().BoolVar(&mcpFlag, "mcp", false, "serve as an MCP server over stdin/stdout")
	cmd.Flags().StringVar(&addr, "addr", "", "HTTP listen address (only with --http); defaults to the config value")
	return cmd
}

// ---------------------------------------------------------------------------
// tools list — enumerate registered tools
// ---------------------------------------------------------------------------

func newToolsCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "tools",
		Short: "Inspect tools",
		Args:  cobra.NoArgs,
	}
	cmd.AddCommand(&cobra.Command{
		Use:   "list",
		Short: "List the registered tools (name and description)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			// Listing tools needs no provider, so we build the registry directly and
			// never require a configured API key.
			reg := buildRegistry()
			tools := reg.List() // already name-sorted
			out := cmd.OutOrStdout()
			for _, t := range tools {
				fmt.Fprintf(out, "%-22s %s\n", t.Name(), t.Description())
			}
			fmt.Fprintf(out, "\n%d tools registered.\n", len(tools))
			return nil
		},
	})
	return cmd
}

// ---------------------------------------------------------------------------
// session ls — list persisted sessions (best-effort)
// ---------------------------------------------------------------------------

func newSessionCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session",
		Short: "Inspect sessions",
		Args:  cobra.NoArgs,
	}
	cmd.AddCommand(newSessionLsCmd(), newSessionShowCmd())
	return cmd
}

// newSessionLsCmd lists the persisted session ids under <AGENTRY_HOME>/sessions.
func newSessionLsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List persisted sessions under ~/.agentry/sessions",
		Long: "List session logs stored under <AGENTRY_HOME>/sessions (JSONL files, " +
			"one per session). Persistence is best-effort; an empty or missing " +
			"directory simply reports no sessions.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			dir := sessionsDir()

			ids, err := sessionStore().List()
			if err != nil {
				return fmt.Errorf("list sessions: %w", err)
			}
			sort.Strings(ids)

			if len(ids) == 0 {
				fmt.Fprintf(out, "no sessions found in %s\n", dir)
				return nil
			}
			for _, id := range ids {
				fmt.Fprintln(out, id)
			}
			fmt.Fprintf(out, "\n%d session(s) in %s\n", len(ids), dir)
			return nil
		},
	}
}

// newSessionShowCmd prints a persisted session's transcript (DESIGN §13:
// "agentry session ls|show <id>"). It loads the JSONL log and renders each
// event in order so a run can be inspected or audited after the fact.
func newSessionShowCmd() *cobra.Command {
	var jsonOut bool
	cmd := &cobra.Command{
		Use:   "show <id>",
		Short: "Print a persisted session's transcript",
		Long: "Load the session log stored under <AGENTRY_HOME>/sessions and print its " +
			"events in order (user/assistant/tool calls + results). Pass --json to emit " +
			"the raw event records instead of the human-readable transcript.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := strings.TrimSpace(args[0])
			out := cmd.OutOrStdout()

			sess, err := sessionStore().Load(id)
			if err != nil {
				if errors.Is(err, session.ErrNotFound) {
					return fmt.Errorf("no such session %q in %s", id, sessionsDir())
				}
				return fmt.Errorf("load session %q: %w", id, err)
			}

			events := sess.Events()
			if jsonOut {
				return printSessionJSON(out, sess, events)
			}
			printSessionTranscript(out, sess, events)
			return nil
		},
	}
	cmd.Flags().BoolVar(&jsonOut, "json", false, "emit raw JSON event records instead of a transcript")
	return cmd
}

// printSessionTranscript renders a loaded session as a readable transcript.
func printSessionTranscript(out io.Writer, sess *session.Session, events []session.Event) {
	fmt.Fprintf(out, "session: %s\n", sess.ID)
	if sess.Model != "" {
		fmt.Fprintf(out, "model:   %s\n", sess.Model)
	}
	if sess.Title != "" {
		fmt.Fprintf(out, "title:   %s\n", sess.Title)
	}
	if sess.Cwd != "" {
		fmt.Fprintf(out, "cwd:     %s\n", sess.Cwd)
	}
	fmt.Fprintf(out, "events:  %d\n\n", len(events))

	for _, e := range events {
		switch e.Type {
		case session.EvUser:
			fmt.Fprintf(out, "[user]\n%s\n\n", e.Text)
		case session.EvAssistant:
			fmt.Fprintf(out, "[assistant]\n%s\n\n", e.Text)
		case session.EvToolCall:
			fmt.Fprintf(out, "[tool-call] %s", e.Tool)
			if e.CallID != "" {
				fmt.Fprintf(out, " (%s)", e.CallID)
			}
			if e.Args != nil {
				if b, err := json.Marshal(e.Args); err == nil {
					fmt.Fprintf(out, " %s", string(b))
				}
			}
			fmt.Fprintln(out)
		case session.EvToolResult:
			status := "ok"
			if e.IsError {
				status = "error"
			}
			fmt.Fprintf(out, "[tool-result] %s [%s]\n%s\n\n", e.Tool, status, e.Text)
		case session.EvMeta:
			if b, err := json.Marshal(e.Meta); err == nil {
				fmt.Fprintf(out, "[meta] %s\n", string(b))
			}
		case session.EvError:
			fmt.Fprintf(out, "[error] %s\n\n", e.Text)
		}
	}
}

// printSessionJSON emits the loaded session as a single JSON object (header +
// events) so the transcript is machine-consumable.
func printSessionJSON(out io.Writer, sess *session.Session, events []session.Event) error {
	payload := struct {
		ID     string          `json:"id"`
		Title  string          `json:"title,omitempty"`
		Model  string          `json:"model,omitempty"`
		Cwd    string          `json:"cwd,omitempty"`
		Events []session.Event `json:"events"`
	}{
		ID:     sess.ID,
		Title:  sess.Title,
		Model:  sess.Model,
		Cwd:    sess.Cwd,
		Events: events,
	}
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(payload)
}

// ---------------------------------------------------------------------------
// mcp add — register/test-connect an MCP server (best-effort)
// ---------------------------------------------------------------------------

func newMCPCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "mcp",
		Short: "Manage MCP server connections",
		Args:  cobra.NoArgs,
	}
	cmd.AddCommand(&cobra.Command{
		Use:   "add <command> [args...]",
		Short: "Test-connect to an MCP server and list the tools it exposes",
		Long: "Spawn the given MCP server command, perform the JSON-RPC handshake, and " +
			"print the tools it advertises. This validates that a server is reachable " +
			"and its tools would be proxied into agentry as local tools. The " +
			"subprocess is shut down before the command returns.",
		Args: cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			command := args[0]
			var serverArgs []string
			if len(args) > 1 {
				serverArgs = args[1:]
			}

			ctx, stop := signalContext()
			defer stop()

			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "connecting to MCP server: %s %s\n", command, strings.Join(serverArgs, " "))

			client, err := mcp.Connect(ctx, command, serverArgs)
			if err != nil {
				return fmt.Errorf("connect to MCP server: %w", err)
			}
			defer client.Close()

			tools := client.Tools()
			if len(tools) == 0 {
				fmt.Fprintln(out, "connected: the server advertises no tools")
				return nil
			}
			fmt.Fprintf(out, "connected: %d tool(s) advertised:\n", len(tools))
			for _, t := range tools {
				fmt.Fprintf(out, "  %-22s %s\n", t.Name, t.Description)
			}
			return nil
		},
	})
	return cmd
}

// ---------------------------------------------------------------------------
// version
// ---------------------------------------------------------------------------

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the agentry version",
		Args:  cobra.NoArgs,
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "agentry %s\n", version)
		},
	}
}
