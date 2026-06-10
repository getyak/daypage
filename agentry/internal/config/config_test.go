package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fakeEnv builds a getenv func backed by a map, for deterministic env layering.
func fakeEnv(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestDefaults(t *testing.T) {
	cfg := Defaults()
	if cfg.DefaultProvider != DefaultProviderName {
		t.Fatalf("DefaultProvider = %q, want %q", cfg.DefaultProvider, DefaultProviderName)
	}
	claude, ok := cfg.Providers[ClaudeProviderName]
	if !ok {
		t.Fatalf("missing default %q provider", ClaudeProviderName)
	}
	if claude.Kind != KindAnthropic || claude.APIKeyEnv != EnvAnthropicAPIKey || claude.Model != DefaultClaudeModel {
		t.Fatalf("claude defaults wrong: %+v", claude)
	}
	oa, ok := cfg.Providers[OpenAIProviderName]
	if !ok || oa.Kind != KindOpenAICompat || oa.BaseURL != DefaultOpenAIBaseURL || oa.APIKeyEnv != EnvOpenAIAPIKey {
		t.Fatalf("openai defaults wrong: %+v", oa)
	}
	ds, ok := cfg.Providers[DashScopeProviderName]
	if !ok || ds.Kind != KindOpenAICompat || ds.BaseURL != DefaultDashScopeBaseURL || ds.APIKeyEnv != EnvDashScopeAPIKey {
		t.Fatalf("dashscope defaults wrong: %+v", ds)
	}
}

// TestEnvOverride is the required env-override test: env values must win over the
// built-in defaults, and OPENAI_BASE_URL must retarget the openai provider.
func TestEnvOverride(t *testing.T) {
	cfg := Defaults()
	applyEnv(cfg, fakeEnv(map[string]string{
		EnvProvider:      "dashscope",
		EnvModel:         "qwen-max",
		EnvSearchURL:     "https://search.example/api",
		EnvOpenAIBaseURL: "https://proxy.local/v1",
	}))

	if cfg.DefaultProvider != "dashscope" {
		t.Errorf("DefaultProvider = %q, want dashscope", cfg.DefaultProvider)
	}
	if cfg.Model != "qwen-max" {
		t.Errorf("Model = %q, want qwen-max", cfg.Model)
	}
	if cfg.SearchURL != "https://search.example/api" {
		t.Errorf("SearchURL = %q, want override", cfg.SearchURL)
	}
	if got := cfg.Providers[OpenAIProviderName].BaseURL; got != "https://proxy.local/v1" {
		t.Errorf("openai BaseURL = %q, want proxy override", got)
	}
	// DashScope keeps its fixed base URL; OPENAI_BASE_URL must not touch it.
	if got := cfg.Providers[DashScopeProviderName].BaseURL; got != DefaultDashScopeBaseURL {
		t.Errorf("dashscope BaseURL = %q, should be untouched", got)
	}
}

func TestEnvEmptyDoesNotClobber(t *testing.T) {
	cfg := Defaults()
	applyEnv(cfg, fakeEnv(map[string]string{})) // all empty
	if cfg.DefaultProvider != DefaultProviderName {
		t.Errorf("empty env clobbered DefaultProvider: %q", cfg.DefaultProvider)
	}
	if cfg.Model != "" {
		t.Errorf("empty env set Model: %q", cfg.Model)
	}
}

// TestFilePartialMergePreservesBaseline checks that a partial provider override in
// the config file (e.g. only Model) keeps the baseline APIKeyEnv for that provider,
// and that file values override defaults but are themselves overridden by env.
func TestFilePartialMergePreservesBaseline(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	file := `{
	  "default_provider": "openai",
	  "providers": {
	    "claude": { "model": "claude-opus-4-6" },
	    "custom": { "kind": "openaicompat", "base_url": "https://x/v1", "api_key_env": "X_KEY" }
	  },
	  "serve": { "addr": "0.0.0.0:9000" }
	}`
	if err := os.WriteFile(path, []byte(file), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := Defaults()
	if err := applyFile(cfg, path); err != nil {
		t.Fatalf("applyFile: %v", err)
	}

	if cfg.DefaultProvider != "openai" {
		t.Errorf("file DefaultProvider not applied: %q", cfg.DefaultProvider)
	}
	claude := cfg.Providers[ClaudeProviderName]
	if claude.Model != "claude-opus-4-6" {
		t.Errorf("file model not applied: %q", claude.Model)
	}
	if claude.APIKeyEnv != EnvAnthropicAPIKey { // preserved from defaults
		t.Errorf("baseline APIKeyEnv lost on partial merge: %q", claude.APIKeyEnv)
	}
	if claude.Kind != KindAnthropic { // preserved
		t.Errorf("baseline Kind lost: %q", claude.Kind)
	}
	custom, ok := cfg.Providers["custom"]
	if !ok || custom.BaseURL != "https://x/v1" || custom.APIKeyEnv != "X_KEY" {
		t.Errorf("new provider from file wrong: %+v", custom)
	}
	if cfg.Serve.Addr != "0.0.0.0:9000" {
		t.Errorf("serve addr not applied: %q", cfg.Serve.Addr)
	}

	// Env still wins over the file.
	applyEnv(cfg, fakeEnv(map[string]string{EnvProvider: "dashscope"}))
	if cfg.DefaultProvider != "dashscope" {
		t.Errorf("env did not override file DefaultProvider: %q", cfg.DefaultProvider)
	}
}

func TestApplyFileMissingIsNoError(t *testing.T) {
	cfg := Defaults()
	if err := applyFile(cfg, filepath.Join(t.TempDir(), "does-not-exist.json")); err != nil {
		t.Fatalf("missing file should not error, got %v", err)
	}
}

func TestApplyFileMalformedIsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := applyFile(Defaults(), path); err == nil {
		t.Fatal("malformed file should error")
	}
}

func TestResolveAPIKey(t *testing.T) {
	cfg := Defaults()
	t.Setenv(EnvAnthropicAPIKey, "sk-ant-test")
	t.Setenv(EnvDashScopeAPIKey, "sk-ds-test")

	if got := cfg.ResolveAPIKey(ClaudeProviderName); got != "sk-ant-test" {
		t.Errorf("claude key = %q, want sk-ant-test", got)
	}
	if got := cfg.ResolveAPIKey(DashScopeProviderName); got != "sk-ds-test" {
		t.Errorf("dashscope key = %q, want sk-ds-test", got)
	}
	// Empty name resolves via DefaultProvider (claude).
	if got := cfg.ResolveAPIKey(""); got != "sk-ant-test" {
		t.Errorf("default key = %q, want sk-ant-test", got)
	}
	// Unknown provider -> empty.
	if got := cfg.ResolveAPIKey("nope"); got != "" {
		t.Errorf("unknown provider key = %q, want empty", got)
	}
}

func TestResolveModel(t *testing.T) {
	cfg := Defaults()
	// No global override -> provider's own model.
	if got := cfg.ResolveModel(ClaudeProviderName); got != DefaultClaudeModel {
		t.Errorf("ResolveModel(claude) = %q, want %q", got, DefaultClaudeModel)
	}
	// Global override wins.
	cfg.Model = "global-model"
	if got := cfg.ResolveModel(ClaudeProviderName); got != "global-model" {
		t.Errorf("ResolveModel with global = %q, want global-model", got)
	}
}

// TestEnvOverridesRetryAndWeb covers the new operator-tunable retry/backoff and
// web-tool bounds: integer AGENTRY_* env values must populate the Retry and Web
// config blocks, and a non-integer value must be ignored (leaving the field at
// its prior value) rather than crashing.
func TestEnvOverridesRetryAndWeb(t *testing.T) {
	cfg := Defaults()
	applyEnv(cfg, fakeEnv(map[string]string{
		EnvRetryMaxRetries: "7",
		EnvRetryBaseMs:     "250",
		EnvRetryCapMs:      "9000",
		EnvWebTimeoutMs:    "3000",
		EnvWebMaxRedirects: "2",
		EnvWebMaxBytes:     "1048576",
	}))

	if cfg.Retry.MaxRetries != 7 || cfg.Retry.BaseMs != 250 || cfg.Retry.CapMs != 9000 {
		t.Fatalf("retry env not applied: %+v", cfg.Retry)
	}
	if cfg.Web.TimeoutMs != 3000 || cfg.Web.MaxRedirects != 2 || cfg.Web.MaxBytes != 1048576 {
		t.Fatalf("web env not applied: %+v", cfg.Web)
	}

	// A garbage integer is ignored, not fatal, and does not clobber the value.
	cfg2 := Defaults()
	cfg2.Retry.MaxRetries = 3
	applyEnv(cfg2, fakeEnv(map[string]string{EnvRetryMaxRetries: "not-a-number"}))
	if cfg2.Retry.MaxRetries != 3 {
		t.Fatalf("unparseable retry env clobbered field: %d", cfg2.Retry.MaxRetries)
	}
}

// TestRetryPolicyMapping verifies RetryPolicy maps the ms-based config onto a
// retry.Policy in time.Duration units, and that an unset config yields zero
// durations (which retry's normalize fills with its own defaults downstream).
func TestRetryPolicyMapping(t *testing.T) {
	cfg := Defaults()
	cfg.Retry = RetryConfig{MaxRetries: 5, BaseMs: 200, CapMs: 8000}
	p := cfg.RetryPolicy()
	if p.MaxRetries != 5 {
		t.Errorf("MaxRetries = %d, want 5", p.MaxRetries)
	}
	if p.BaseDelay != 200*time.Millisecond {
		t.Errorf("BaseDelay = %v, want 200ms", p.BaseDelay)
	}
	if p.MaxDelay != 8000*time.Millisecond {
		t.Errorf("MaxDelay = %v, want 8s", p.MaxDelay)
	}

	// Unset -> zero durations (retry.Policy.normalize handles the rest).
	zero := Defaults().RetryPolicy()
	if zero.BaseDelay != 0 || zero.MaxDelay != 0 {
		t.Errorf("unset RetryPolicy should be zero durations, got %+v", zero)
	}
}

// TestFileMergesRetryAndWeb confirms the retry/web blocks round-trip through the
// JSON config file and that env still overrides the file value.
func TestFileMergesRetryAndWeb(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	file := `{
	  "retry": { "max_retries": 4, "base_ms": 100, "cap_ms": 5000 },
	  "web":   { "timeout_ms": 2500, "max_redirects": 3, "max_bytes": 2048 }
	}`
	if err := os.WriteFile(path, []byte(file), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := Defaults()
	if err := applyFile(cfg, path); err != nil {
		t.Fatalf("applyFile: %v", err)
	}
	if cfg.Retry.MaxRetries != 4 || cfg.Retry.BaseMs != 100 || cfg.Retry.CapMs != 5000 {
		t.Fatalf("file retry not applied: %+v", cfg.Retry)
	}
	if cfg.Web.TimeoutMs != 2500 || cfg.Web.MaxRedirects != 3 || cfg.Web.MaxBytes != 2048 {
		t.Fatalf("file web not applied: %+v", cfg.Web)
	}

	// Env wins over file.
	applyEnv(cfg, fakeEnv(map[string]string{EnvRetryMaxRetries: "9"}))
	if cfg.Retry.MaxRetries != 9 {
		t.Fatalf("env did not override file retry: %d", cfg.Retry.MaxRetries)
	}
}

func TestLoadUsesAgentryHome(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("AGENTRY_HOME", dir)
	// Clear env that could perturb the assertion.
	t.Setenv(EnvProvider, "")
	t.Setenv(EnvModel, "")
	t.Setenv(EnvOpenAIBaseURL, "")

	file := `{ "model": "from-file-model" }`
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(file), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Model != "from-file-model" {
		t.Errorf("Load did not read file under AGENTRY_HOME: Model=%q", cfg.Model)
	}
	if cfg.DefaultProvider != DefaultProviderName {
		t.Errorf("Load default provider = %q", cfg.DefaultProvider)
	}
}
