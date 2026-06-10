// Package config implements Agentry's layered configuration.
//
// Resolution precedence, lowest to highest:
//
//	built-in defaults  ->  config file (~/.agentry/config.json)  ->  environment
//
// CLI flags sit above all of these but are applied by the caller (e.g. the cobra
// command layer) after Load returns, so this package stays free of flag plumbing.
//
// Only stdlib is used (encoding/json, os, path/filepath). Secrets are never read
// from the config file: a ProviderConfig names an *environment variable*
// (APIKeyEnv) that holds the key, and ResolveAPIKey reads it at call time. This
// keeps keys out of any persisted config or session log.
package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/kubbot/agentry/internal/core/provider/retry"
)

// ProviderKind enumerates the adapter family a provider entry maps to. The agent
// runtime selects a concrete adapter (anthropic vs. openai-compatible) from this.
const (
	KindAnthropic    = "anthropic"
	KindOpenAICompat = "openaicompat"
)

// Default identifiers and endpoints. Exposed so callers/tests can reference them
// without duplicating string literals.
const (
	DefaultProviderName = "claude"

	ClaudeProviderName    = "claude"
	OpenAIProviderName    = "openai"
	DashScopeProviderName = "dashscope"

	DefaultClaudeModel = "claude-sonnet-4-6"

	DefaultOpenAIBaseURL    = "https://api.openai.com/v1"
	DefaultDashScopeBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

	DefaultServeAddr = "127.0.0.1:8787"
)

// Environment variable names consulted by Load and ResolveAPIKey.
const (
	EnvProvider      = "AGENTRY_PROVIDER"
	EnvModel         = "AGENTRY_MODEL"
	EnvSearchURL     = "AGENTRY_SEARCH_URL"
	EnvOpenAIBaseURL = "OPENAI_BASE_URL"

	EnvAnthropicAPIKey = "ANTHROPIC_API_KEY"
	EnvOpenAIAPIKey    = "OPENAI_API_KEY"
	EnvDashScopeAPIKey = "DASHSCOPE_API_KEY"

	// Transient-failure retry tunables, shared by the provider adapters and the
	// web tool family (web.fetch/web.extract/web.search). Previously hard-wired
	// to retry.DefaultPolicy; now operator-tunable without recompiling.
	EnvRetryMaxRetries = "AGENTRY_RETRY_MAX_RETRIES" // integer >= 0
	EnvRetryBaseMs     = "AGENTRY_RETRY_BASE_MS"     // first-retry backoff, ms
	EnvRetryCapMs      = "AGENTRY_RETRY_CAP_MS"      // per-retry backoff ceiling, ms

	// web.fetch / web.extract / web.search operational caps. Previously fixed
	// package constants; surfaced here so deployments can tighten or relax them.
	EnvWebTimeoutMs    = "AGENTRY_WEB_TIMEOUT_MS"    // whole-request timeout, ms
	EnvWebMaxRedirects = "AGENTRY_WEB_MAX_REDIRECTS" // redirect-chain cap
	EnvWebMaxBytes     = "AGENTRY_WEB_MAX_BYTES"     // response-body hard cap, bytes
)

// ProviderConfig describes how to reach one LLM backend. The API key itself is
// not stored here; APIKeyEnv names the environment variable that holds it.
type ProviderConfig struct {
	Kind      string `json:"kind"`               // KindAnthropic | KindOpenAICompat
	BaseURL   string `json:"base_url,omitempty"` // ignored for the Anthropic SDK; required for openaicompat
	APIKeyEnv string `json:"api_key_env"`        // env var name holding the secret
	Model     string `json:"model,omitempty"`    // per-provider default model
}

// ServeConfig holds defaults for the `serve` transports.
type ServeConfig struct {
	Addr string `json:"addr,omitempty"` // HTTP listen address
}

// RetryConfig governs transient-failure retry/backoff for outbound HTTP, shared
// by the provider adapters and the web tool family. A non-positive field falls
// back to the package default (see retry.DefaultPolicy); MaxRetries == 0 means
// "no retries" only when explicitly set, since the zero value is taken as unset.
type RetryConfig struct {
	// MaxRetries is the number of retries after the initial attempt. A negative
	// value disables retrying.
	MaxRetries int `json:"max_retries,omitempty"`
	// BaseMs is the first-retry backoff in milliseconds (doubles each retry).
	BaseMs int `json:"base_ms,omitempty"`
	// CapMs caps the per-retry backoff (before jitter) in milliseconds.
	CapMs int `json:"cap_ms,omitempty"`
}

// WebConfig carries the web.fetch/web.extract/web.search operational caps. A
// zero field means "use the tool's built-in default".
type WebConfig struct {
	// TimeoutMs bounds the whole HTTP round trip in milliseconds.
	TimeoutMs int `json:"timeout_ms,omitempty"`
	// MaxRedirects caps the redirect chain web.fetch will follow.
	MaxRedirects int `json:"max_redirects,omitempty"`
	// MaxBytes is the absolute response-body ceiling in bytes.
	MaxBytes int `json:"max_bytes,omitempty"`
}

// Config is the fully resolved runtime configuration.
type Config struct {
	// DefaultProvider names the entry in Providers used when no per-request
	// provider is specified.
	DefaultProvider string `json:"default_provider,omitempty"`
	// Model is the global default model. An empty value falls back to the
	// selected provider's own Model.
	Model string `json:"model,omitempty"`
	// Providers maps a provider name (e.g. "claude") to its configuration.
	Providers map[string]ProviderConfig `json:"providers,omitempty"`
	// Serve carries transport defaults.
	Serve ServeConfig `json:"serve,omitempty"`
	// SearchURL is the endpoint for the web.search tool backend, if configured.
	SearchURL string `json:"search_url,omitempty"`
	// Retry tunes transient-failure retry/backoff for outbound HTTP.
	Retry RetryConfig `json:"retry,omitempty"`
	// Web tunes the web tool family's request bounds.
	Web WebConfig `json:"web,omitempty"`
}

// Defaults returns a fresh Config populated with the built-in baseline. Each call
// allocates a new map so callers may mutate the result freely.
func Defaults() *Config {
	return &Config{
		DefaultProvider: DefaultProviderName,
		Model:           "",
		Providers: map[string]ProviderConfig{
			ClaudeProviderName: {
				Kind:      KindAnthropic,
				APIKeyEnv: EnvAnthropicAPIKey,
				Model:     DefaultClaudeModel,
			},
			OpenAIProviderName: {
				Kind:      KindOpenAICompat,
				BaseURL:   DefaultOpenAIBaseURL,
				APIKeyEnv: EnvOpenAIAPIKey,
			},
			DashScopeProviderName: {
				Kind:      KindOpenAICompat,
				BaseURL:   DefaultDashScopeBaseURL,
				APIKeyEnv: EnvDashScopeAPIKey,
			},
		},
		Serve: ServeConfig{Addr: DefaultServeAddr},
	}
}

// ConfigDir returns the directory holding Agentry's config and state, honoring
// AGENTRY_HOME when set; otherwise ~/.agentry. It does not create the directory.
func ConfigDir() string {
	if h := os.Getenv("AGENTRY_HOME"); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		// Fall back to a relative path rather than panicking; a missing home
		// directory is unusual but should not crash configuration loading.
		return ".agentry"
	}
	return filepath.Join(home, ".agentry")
}

// configFilePath is the JSON config location: <ConfigDir>/config.json.
func configFilePath() string {
	return filepath.Join(ConfigDir(), "config.json")
}

// Load builds the effective configuration by layering defaults, the on-disk
// config file (if any), and environment overrides, in that order. A missing
// config file is not an error; a present-but-malformed one is.
func Load() (*Config, error) {
	cfg := Defaults()

	if err := applyFile(cfg, configFilePath()); err != nil {
		return nil, err
	}
	applyEnv(cfg, os.Getenv)

	return cfg, nil
}

// applyFile merges a JSON config file at path into cfg. Absence is silently
// ignored. Only fields present (non-zero) in the file override the defaults;
// provider entries are merged field-by-field so a partial override in the file
// does not erase baseline fields (e.g. APIKeyEnv) for that provider.
func applyFile(cfg *Config, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil // no file: nothing to merge
		}
		return err
	}

	var fileCfg Config
	if err := json.Unmarshal(data, &fileCfg); err != nil {
		return err
	}

	if fileCfg.DefaultProvider != "" {
		cfg.DefaultProvider = fileCfg.DefaultProvider
	}
	if fileCfg.Model != "" {
		cfg.Model = fileCfg.Model
	}
	if fileCfg.SearchURL != "" {
		cfg.SearchURL = fileCfg.SearchURL
	}
	if fileCfg.Serve.Addr != "" {
		cfg.Serve.Addr = fileCfg.Serve.Addr
	}
	// Retry / Web blocks: only non-zero file fields override the (zero) baseline,
	// so a partial block leaves the rest at the tool/provider default.
	if fileCfg.Retry.MaxRetries != 0 {
		cfg.Retry.MaxRetries = fileCfg.Retry.MaxRetries
	}
	if fileCfg.Retry.BaseMs != 0 {
		cfg.Retry.BaseMs = fileCfg.Retry.BaseMs
	}
	if fileCfg.Retry.CapMs != 0 {
		cfg.Retry.CapMs = fileCfg.Retry.CapMs
	}
	if fileCfg.Web.TimeoutMs != 0 {
		cfg.Web.TimeoutMs = fileCfg.Web.TimeoutMs
	}
	if fileCfg.Web.MaxRedirects != 0 {
		cfg.Web.MaxRedirects = fileCfg.Web.MaxRedirects
	}
	if fileCfg.Web.MaxBytes != 0 {
		cfg.Web.MaxBytes = fileCfg.Web.MaxBytes
	}
	for name, fp := range fileCfg.Providers {
		merged := cfg.Providers[name] // zero value if the provider is new
		if fp.Kind != "" {
			merged.Kind = fp.Kind
		}
		if fp.BaseURL != "" {
			merged.BaseURL = fp.BaseURL
		}
		if fp.APIKeyEnv != "" {
			merged.APIKeyEnv = fp.APIKeyEnv
		}
		if fp.Model != "" {
			merged.Model = fp.Model
		}
		if cfg.Providers == nil {
			cfg.Providers = map[string]ProviderConfig{}
		}
		cfg.Providers[name] = merged
	}
	return nil
}

// applyEnv overlays environment overrides onto cfg. getenv is injected so tests
// can supply a deterministic environment without touching the real process env.
func applyEnv(cfg *Config, getenv func(string) string) {
	if v := getenv(EnvProvider); v != "" {
		cfg.DefaultProvider = v
	}
	if v := getenv(EnvModel); v != "" {
		cfg.Model = v
	}
	if v := getenv(EnvSearchURL); v != "" {
		cfg.SearchURL = v
	}
	// OPENAI_BASE_URL retargets the openai (and any openaicompat) endpoint. We
	// apply it to the "openai" provider specifically so DashScope keeps its own
	// fixed base URL unless the file overrode it.
	if v := getenv(EnvOpenAIBaseURL); v != "" {
		if p, ok := cfg.Providers[OpenAIProviderName]; ok {
			p.BaseURL = v
			cfg.Providers[OpenAIProviderName] = p
		}
	}

	// Retry tunables (integers). A present-but-unparseable value is ignored so a
	// typo never crashes startup; it simply leaves the field at its prior value.
	if n, ok := atoiEnv(getenv, EnvRetryMaxRetries); ok {
		cfg.Retry.MaxRetries = n
	}
	if n, ok := atoiEnv(getenv, EnvRetryBaseMs); ok {
		cfg.Retry.BaseMs = n
	}
	if n, ok := atoiEnv(getenv, EnvRetryCapMs); ok {
		cfg.Retry.CapMs = n
	}

	// Web tool bounds (integers).
	if n, ok := atoiEnv(getenv, EnvWebTimeoutMs); ok {
		cfg.Web.TimeoutMs = n
	}
	if n, ok := atoiEnv(getenv, EnvWebMaxRedirects); ok {
		cfg.Web.MaxRedirects = n
	}
	if n, ok := atoiEnv(getenv, EnvWebMaxBytes); ok {
		cfg.Web.MaxBytes = n
	}
}

// atoiEnv reads the named env var via getenv and parses it as a base-10 integer.
// It returns ok=false when the variable is unset/blank or fails to parse, so the
// caller leaves the corresponding field untouched (a bad value never overrides a
// good default and never errors).
func atoiEnv(getenv func(string) string, name string) (int, bool) {
	v := strings.TrimSpace(getenv(name))
	if v == "" {
		return 0, false
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, false
	}
	return n, true
}

// ResolveProvider returns the ProviderConfig for the given name, falling back to
// DefaultProvider when name is empty. ok reports whether a matching entry exists.
func (c *Config) ResolveProvider(name string) (ProviderConfig, bool) {
	if name == "" {
		name = c.DefaultProvider
	}
	p, ok := c.Providers[name]
	return p, ok
}

// ResolveModel returns the effective model for a provider: the global Model
// override if set, otherwise the provider's own Model.
func (c *Config) ResolveModel(providerName string) string {
	if c.Model != "" {
		return c.Model
	}
	if p, ok := c.ResolveProvider(providerName); ok {
		return p.Model
	}
	return ""
}

// ResolveAPIKey returns the secret for the named provider by reading the
// environment variable that the provider's APIKeyEnv points to. An empty result
// means the key is unset or the provider is unknown.
func (c *Config) ResolveAPIKey(providerName string) string {
	if providerName == "" {
		providerName = c.DefaultProvider
	}
	p, ok := c.Providers[providerName]
	if !ok || p.APIKeyEnv == "" {
		return ""
	}
	return os.Getenv(p.APIKeyEnv)
}

// RetryPolicy maps the resolved RetryConfig onto a retry.Policy for the provider
// adapters and web tools. Fields left at their zero/default value are carried as
// zero durations, which retry.Policy.normalize() fills with retry's own defaults
// — so an unconfigured deployment behaves exactly as before this knob existed.
// A negative MaxRetries (explicit "disable retries") is preserved; retry treats
// it as zero retries.
func (c *Config) RetryPolicy() retry.Policy {
	return retry.Policy{
		MaxRetries: c.Retry.MaxRetries,
		BaseDelay:  time.Duration(c.Retry.BaseMs) * time.Millisecond,
		MaxDelay:   time.Duration(c.Retry.CapMs) * time.Millisecond,
	}
}
