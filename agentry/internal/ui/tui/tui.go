// Package tui implements Agentry's interactive terminal workbench.
//
// It is a *client* of the Engine, not a second brain: it owns no agent logic. A
// single Bubble Tea model renders the live session as a scrolling transcript
// (assistant text plus bordered tool-call cards), accepts a prompt in a bottom
// input box, and on Enter runs eng.Run in a goroutine while streaming the
// session's event log back into the model.
//
// Streaming discipline mirrors the HTTP transport (DESIGN §6/§11): we
// session.Subscribe() *before* calling Run so the first events cannot be missed,
// then forward each event into Bubble Tea as a tea.Msg. Because session.Append
// fans out to subscribers with a *non-blocking* send (a slow subscriber is
// dropped, see session.Session.Append), we relay events on a dedicated goroutine
// that pushes into the program via Program.Send — this drains the subscription
// promptly and never stalls the Engine.
//
// The model file deliberately hand-rolls its input field and spinner so the only
// external dependencies are the two named for this task: bubbletea and lipgloss.
package tui

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/kubbot/agentry/internal/core/agent"
	"github.com/kubbot/agentry/internal/core/session"
)

// Run starts the TUI program against eng and blocks until the user quits
// (Ctrl+C / esc) or ctx is cancelled. It owns the lifecycle of a single session.
func Run(ctx context.Context, eng *agent.Engine) error {
	if eng == nil {
		return fmt.Errorf("tui: engine is nil")
	}

	sess := session.New(fmt.Sprintf("tui-%d", time.Now().UnixNano()))

	m := newModel(ctx, eng, sess)

	// WithAltScreen gives us a clean full-screen canvas; WithContext ties the
	// program's lifetime to the caller's ctx so an outer cancellation tears the
	// UI down cleanly.
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithContext(ctx))

	// The model needs a handle to the program so its event-relay and run
	// goroutines can Send messages back in. We can only obtain that handle after
	// constructing the program, so we hand it to the model here.
	m.program = p

	_, err := p.Run()
	// A context cancellation surfaced by Bubble Tea is a normal shutdown, not an
	// error worth bubbling up to the caller.
	if err != nil && ctx.Err() != nil {
		return nil
	}
	return err
}

// ---------------------------------------------------------------------------
// Messages (the tea.Msg types that drive state transitions)
// ---------------------------------------------------------------------------

// sessionEventMsg carries one event from the live session into the model.
type sessionEventMsg struct{ ev session.Event }

// runDoneMsg signals that eng.Run returned, with its final text and error.
type runDoneMsg struct {
	text string
	err  error
}

// spinnerTickMsg advances the working spinner.
type spinnerTickMsg struct{}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// model is the whole TUI state. It is a value type as Bubble Tea expects;
// the *Program handle is the one shared reference, used only to Send messages
// from background goroutines.
type model struct {
	ctx  context.Context
	eng  *agent.Engine
	sess *session.Session

	// program is the running Bubble Tea program, used by background goroutines
	// (event relay, run completion) to push messages back into Update. Set by Run
	// immediately after the program is constructed.
	program *tea.Program

	// transcript holds the rendered, immutable history blocks (assistant
	// messages and tool-call cards) in arrival order. Each entry is a
	// pre-styled, possibly multi-line string.
	transcript []string

	// input is the current contents of the prompt box.
	input string

	// working is true while an eng.Run is in flight; it gates input submission
	// and drives the spinner.
	working bool

	// spinnerFrame indexes the spinner animation.
	spinnerFrame int

	// statusErr holds the last run error, shown in the status line until the
	// next successful submit.
	statusErr string

	width  int
	height int
}

// newModel constructs the initial model. The *Program is attached by Run after
// construction (see Run).
func newModel(ctx context.Context, eng *agent.Engine, sess *session.Session) *model {
	return &model{
		ctx:    ctx,
		eng:    eng,
		sess:   sess,
		width:  80,
		height: 24,
	}
}

// spinnerFrames is a small braille spinner.
var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Init starts the session-event relay so we receive events even before the first
// prompt (and for the lifetime of the program), and kicks off the spinner tick.
func (m *model) Init() tea.Cmd {
	go m.relaySessionEvents()
	return tickSpinner()
}

// relaySessionEvents subscribes to the session and forwards every event into the
// program as a sessionEventMsg. It runs for the whole program lifetime: a single
// subscription survives across multiple prompts, so we never race the
// subscribe-before-run window on the second and later turns. It exits when ctx is
// cancelled (program shutdown), at which point unsubscribe releases the channel.
func (m *model) relaySessionEvents() {
	events, unsubscribe := m.sess.Subscribe()
	defer unsubscribe()

	for {
		select {
		case ev, ok := <-events:
			if !ok {
				return
			}
			// program is set synchronously in Run before p.Run() starts dispatch,
			// so by the time any event can arrive it is non-nil. Guard anyway.
			if m.program != nil {
				m.program.Send(sessionEventMsg{ev: ev})
			}
		case <-m.ctx.Done():
			return
		}
	}
}

// tickSpinner schedules the next spinner frame.
func tickSpinner() tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg {
		return spinnerTickMsg{}
	})
}

// Update is the central state machine.
func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case spinnerTickMsg:
		if m.working {
			m.spinnerFrame = (m.spinnerFrame + 1) % len(spinnerFrames)
		}
		// Keep ticking regardless so the spinner is live the instant work starts.
		return m, tickSpinner()

	case sessionEventMsg:
		m.appendEvent(msg.ev)
		return m, nil

	case runDoneMsg:
		m.working = false
		if msg.err != nil {
			m.statusErr = msg.err.Error()
		}
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)
	}

	return m, nil
}

// handleKey processes keyboard input for the prompt box and global shortcuts.
func (m *model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {

	case tea.KeyCtrlC, tea.KeyEsc:
		return m, tea.Quit

	case tea.KeyEnter:
		return m, m.submit()

	case tea.KeyBackspace:
		if len(m.input) > 0 {
			// Trim one full rune, not one byte, so multibyte input deletes cleanly.
			r := []rune(m.input)
			m.input = string(r[:len(r)-1])
		}
		return m, nil

	case tea.KeyCtrlU:
		// Clear the line — a familiar shell shortcut.
		m.input = ""
		return m, nil

	case tea.KeySpace:
		if !m.working {
			m.input += " "
		}
		return m, nil

	case tea.KeyRunes:
		if !m.working {
			m.input += string(msg.Runes)
		}
		return m, nil
	}

	return m, nil
}

// submit validates the current input and, if non-empty and idle, launches a run.
// It returns a Cmd that starts the Engine in a goroutine and reports completion
// via runDoneMsg. Streaming of intermediate events is handled by the long-lived
// relay goroutine, so submit only needs to own the terminal outcome.
func (m *model) submit() tea.Cmd {
	prompt := strings.TrimSpace(m.input)
	if prompt == "" || m.working {
		return nil
	}

	m.input = ""
	m.working = true
	m.statusErr = ""
	m.spinnerFrame = 0

	eng := m.eng
	sess := m.sess
	ctx := m.ctx

	return func() tea.Msg {
		// The relay goroutine is already subscribed, so every event Run appends
		// (starting with the user event) is delivered. We block here only to learn
		// the final outcome.
		text, err := eng.Run(ctx, sess, prompt)
		return runDoneMsg{text: text, err: err}
	}
}

// appendEvent renders one session event into the transcript. Tool calls and
// results become cards; assistant/user text become plain blocks. Meta/usage
// events are intentionally ignored in the transcript to keep it readable (they
// remain in the session log for transports that want them).
func (m *model) appendEvent(ev session.Event) {
	switch ev.Type {

	case session.EvUser:
		m.transcript = append(m.transcript, m.renderUser(ev.Text))

	case session.EvAssistant:
		if strings.TrimSpace(ev.Text) != "" {
			m.transcript = append(m.transcript, m.renderAssistant(ev.Text))
		}

	case session.EvToolCall:
		m.transcript = append(m.transcript, m.renderToolCall(ev))

	case session.EvToolResult:
		m.transcript = append(m.transcript, m.renderToolResult(ev))

	case session.EvError:
		m.transcript = append(m.transcript, m.renderError(ev.Text))

	case session.EvMeta:
		// Skipped in the transcript; metadata is not conversational content.
	}
}

// ---------------------------------------------------------------------------
// Styles (lipgloss) — modest but distinct per role.
// ---------------------------------------------------------------------------

var (
	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("231")).
			Background(lipgloss.Color("63")).
			Padding(0, 1)

	subtleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))

	userLabelStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("39"))

	assistantLabelStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("213"))

	assistantTextStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))

	errorStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("203"))

	// toolCardStyle gives tool activity a subtle rounded border, per the task.
	toolCardStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("245")).
			Padding(0, 1)

	toolNameStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("78"))

	toolErrStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("203"))

	inputBoxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("63")).
			Padding(0, 1)

	statusStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))

	spinnerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("213"))
)

// contentWidth returns the usable inner width for transcript content, leaving a
// small margin and never going pathologically narrow.
func (m *model) contentWidth() int {
	w := m.width - 2
	if w < 20 {
		w = 20
	}
	return w
}

func (m *model) renderUser(text string) string {
	label := userLabelStyle.Render("you")
	body := wrap(text, m.contentWidth())
	return label + "\n" + body
}

func (m *model) renderAssistant(text string) string {
	label := assistantLabelStyle.Render("agentry")
	body := assistantTextStyle.Render(wrap(text, m.contentWidth()))
	return label + "\n" + body
}

func (m *model) renderError(text string) string {
	return errorStyle.Render("error: ") + wrap(text, m.contentWidth())
}

// renderToolCall renders the model's intent to invoke a tool as a bordered card
// showing the tool name and its (compacted) JSON arguments.
func (m *model) renderToolCall(ev session.Event) string {
	header := toolNameStyle.Render("→ "+ev.Tool) + subtleStyle.Render("  (call)")
	args := argsString(ev.Args)
	inner := header
	if args != "" {
		inner += "\n" + subtleStyle.Render(truncate(args, 600))
	}
	// Width-box the card so the border spans the pane consistently.
	return toolCardStyle.Width(m.cardWidth()).Render(inner)
}

// renderToolResult renders a completed tool call's result in a bordered card,
// flagging error results distinctly.
func (m *model) renderToolResult(ev session.Event) string {
	var header string
	if ev.IsError {
		header = toolErrStyle.Render("✗ "+ev.Tool) + subtleStyle.Render("  (error)")
	} else {
		header = toolNameStyle.Render("✓ "+ev.Tool) + subtleStyle.Render("  (result)")
	}
	body := truncate(strings.TrimRight(ev.Text, "\n"), 1200)
	inner := header
	if strings.TrimSpace(body) != "" {
		inner += "\n" + wrap(body, m.cardWidth()-2)
	}
	style := toolCardStyle
	if ev.IsError {
		style = style.BorderForeground(lipgloss.Color("203"))
	}
	return style.Width(m.cardWidth()).Render(inner)
}

// cardWidth bounds tool cards to the content width.
func (m *model) cardWidth() int {
	w := m.contentWidth()
	if w > 100 {
		w = 100
	}
	return w
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

// View renders the whole screen: header, scrolling transcript (tail-anchored to
// fit the viewport), a status/spinner line, and the input box.
func (m *model) View() string {
	header := m.renderHeader()
	input := m.renderInput()
	status := m.renderStatus()

	// Compute how many lines the transcript may occupy: total height minus the
	// fixed chrome (header, status, input box, and the blank separators).
	chrome := lipgloss.Height(header) + lipgloss.Height(status) + lipgloss.Height(input) + 2
	bodyHeight := m.height - chrome
	if bodyHeight < 1 {
		bodyHeight = 1
	}

	body := m.renderTranscript(bodyHeight)

	return strings.Join([]string{header, body, status, input}, "\n")
}

func (m *model) renderHeader() string {
	title := headerStyle.Render("Agentry")
	hint := subtleStyle.Render("  workbench · enter to send · ctrl+c/esc to quit")
	return title + hint
}

// renderTranscript joins the transcript blocks and tail-anchors them to the
// available height so the most recent activity is always visible (a simple
// scroll-to-bottom, sufficient for a streaming workbench).
func (m *model) renderTranscript(maxLines int) string {
	if len(m.transcript) == 0 {
		return subtleStyle.Render("\n  Ask Agentry anything. Tool calls will appear as cards below.\n")
	}

	full := strings.Join(m.transcript, "\n\n")
	lines := strings.Split(full, "\n")
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	return strings.Join(lines, "\n")
}

// renderStatus shows the spinner + "working" while a run is in flight, the last
// error if one occurred, or an idle hint otherwise.
func (m *model) renderStatus() string {
	switch {
	case m.working:
		sp := spinnerStyle.Render(spinnerFrames[m.spinnerFrame])
		return sp + " " + statusStyle.Render("agentry is working…")
	case m.statusErr != "":
		return errorStyle.Render("✗ ") + statusStyle.Render(truncate(m.statusErr, 200))
	default:
		return statusStyle.Render("ready")
	}
}

// renderInput draws the bottom prompt box with a blinking-free caret.
func (m *model) renderInput() string {
	prompt := "› "
	shown := m.input + "▏" // simple static caret
	if m.working {
		// While working, make it visually clear input is paused.
		shown = subtleStyle.Render("(working — input paused)")
	}
	width := m.width - 4
	if width < 10 {
		width = 10
	}
	return inputBoxStyle.Width(width).Render(prompt + shown)
}

// ---------------------------------------------------------------------------
// Small helpers (no external deps): wrapping, truncation, arg formatting.
// ---------------------------------------------------------------------------

// wrap performs simple word wrapping to width columns. It is rune-aware enough
// for typical CJK/ASCII mixes (counting runes, not bytes) and never panics. It
// preserves explicit newlines in the input.
func wrap(s string, width int) string {
	if width < 1 {
		width = 1
	}
	var out strings.Builder
	for i, line := range strings.Split(s, "\n") {
		if i > 0 {
			out.WriteByte('\n')
		}
		out.WriteString(wrapLine(line, width))
	}
	return out.String()
}

// wrapLine wraps a single (newline-free) line to width runes, breaking on spaces
// where possible and hard-breaking over-long words.
func wrapLine(line string, width int) string {
	words := strings.Fields(line)
	if len(words) == 0 {
		return ""
	}
	var (
		out    strings.Builder
		curLen int
	)
	for _, w := range words {
		wl := runeLen(w)
		switch {
		case curLen == 0:
			// First word on the line: place it, hard-breaking if it alone exceeds.
			out.WriteString(hardBreak(&w, width))
			curLen = runeLen(lastSegment(out.String()))
		case curLen+1+wl <= width:
			out.WriteByte(' ')
			out.WriteString(w)
			curLen += 1 + wl
		default:
			out.WriteByte('\n')
			out.WriteString(hardBreak(&w, width))
			curLen = runeLen(lastSegment(out.String()))
		}
	}
	return out.String()
}

// hardBreak splits a word that is wider than width into width-sized chunks,
// inserting newlines. Returns the (possibly multi-line) rendering.
func hardBreak(word *string, width int) string {
	r := []rune(*word)
	if len(r) <= width {
		return *word
	}
	var b strings.Builder
	for len(r) > width {
		b.WriteString(string(r[:width]))
		b.WriteByte('\n')
		r = r[width:]
	}
	b.WriteString(string(r))
	return b.String()
}

// lastSegment returns the substring after the final newline, used to track the
// current visual line length while wrapping.
func lastSegment(s string) string {
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}

func runeLen(s string) int { return len([]rune(s)) }

// truncate shortens s to at most n runes, appending an ellipsis marker when cut.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}

// argsString renders tool-call Args (stored on the event as `any`, typically a
// json.RawMessage) into a compact single-line-ish string for the card. It is
// defensive: anything unprintable is rendered via fmt.
func argsString(args any) string {
	if args == nil {
		return ""
	}
	switch v := args.(type) {
	case string:
		return compactWhitespace(v)
	case []byte:
		return compactWhitespace(string(v))
	case fmt.Stringer:
		return compactWhitespace(v.String())
	default:
		// json.RawMessage is a []byte under the hood but may not match the []byte
		// case across type identities; fall back to fmt which prints it readably.
		return compactWhitespace(fmt.Sprintf("%s", v))
	}
}

// compactWhitespace collapses runs of whitespace into single spaces so JSON args
// fit on a card without their pretty-printed newlines.
func compactWhitespace(s string) string {
	var b strings.Builder
	prevSpace := false
	for _, r := range s {
		if unicode.IsSpace(r) {
			if !prevSpace {
				b.WriteByte(' ')
				prevSpace = true
			}
			continue
		}
		b.WriteRune(r)
		prevSpace = false
	}
	return strings.TrimSpace(b.String())
}
