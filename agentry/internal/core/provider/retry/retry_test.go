package retry

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// stubRT is a programmable http.RoundTripper. Each call pops the next scripted
// result; it also records the request bodies it saw so body-replay can be
// verified.
type stubRT struct {
	mu        sync.Mutex
	results   []result
	calls     int32
	gotBodies []string
}

type result struct {
	status int // 0 => return err instead
	err    error
	header map[string]string // optional response headers
}

func (s *stubRT) RoundTrip(r *http.Request) (*http.Response, error) {
	n := int(atomic.AddInt32(&s.calls, 1)) - 1

	// Record the body to prove each attempt got a fresh, complete copy.
	body := ""
	if r.Body != nil {
		b, _ := io.ReadAll(r.Body)
		body = string(b)
	}
	s.mu.Lock()
	s.gotBodies = append(s.gotBodies, body)
	res := result{status: http.StatusOK}
	if n < len(s.results) {
		res = s.results[n]
	}
	s.mu.Unlock()

	if res.status == 0 {
		return nil, res.err
	}
	h := http.Header{}
	for k, v := range res.header {
		h.Set(k, v)
	}
	return &http.Response{
		StatusCode: res.status,
		Header:     h,
		Body:       io.NopCloser(strings.NewReader(fmt.Sprintf("body-for-%d", n))),
	}, nil
}

// newReq builds a POST with a replayable buffered body, like the providers do.
func newReq(t *testing.T, ctx context.Context, payload string) *http.Request {
	t.Helper()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://x.test/v1", strings.NewReader(payload))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	return req
}

// noSleep makes backoff instantaneous so tests don't spend real time, while
// still honoring an already-cancelled context.
func noSleep(rt *RoundTripper) {
	rt.sleep = func(ctx context.Context, _ time.Duration) error {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			return nil
		}
	}
}

func TestRetriesThenSucceeds(t *testing.T) {
	stub := &stubRT{results: []result{
		{status: http.StatusServiceUnavailable}, // 503
		{status: http.StatusTooManyRequests},    // 429
		{status: http.StatusOK},
	}}
	rt := New(stub, DefaultPolicy())
	noSleep(rt)

	resp, err := rt.RoundTrip(newReq(t, context.Background(), `{"a":1}`))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 3 {
		t.Fatalf("attempts = %d, want 3", got)
	}
	// Every attempt must have received the full, identical body.
	for i, b := range stub.gotBodies {
		if b != `{"a":1}` {
			t.Errorf("attempt %d body = %q, want full payload replayed", i, b)
		}
	}
}

func TestExhaustsRetries(t *testing.T) {
	stub := &stubRT{results: []result{
		{status: 503}, {status: 503}, {status: 503}, {status: 503}, {status: 503},
	}}
	rt := New(stub, Policy{MaxRetries: 2, BaseDelay: time.Millisecond, MaxDelay: time.Millisecond})
	noSleep(rt)

	resp, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// MaxRetries=2 => 1 initial + 2 retries = 3 attempts, final 503 returned.
	if resp.StatusCode != 503 {
		t.Errorf("status = %d, want 503 (exhausted)", resp.StatusCode)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 3 {
		t.Fatalf("attempts = %d, want 3 (1+2)", got)
	}
}

func TestNoRetryOn4xx(t *testing.T) {
	for _, code := range []int{http.StatusBadRequest, http.StatusUnauthorized, http.StatusNotFound} {
		stub := &stubRT{results: []result{{status: code}, {status: http.StatusOK}}}
		rt := New(stub, DefaultPolicy())
		noSleep(rt)
		resp, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
		if err != nil {
			t.Fatalf("code %d: unexpected error %v", code, err)
		}
		if resp.StatusCode != code {
			t.Errorf("code %d: returned %d, want no retry", code, resp.StatusCode)
		}
		if got := atomic.LoadInt32(&stub.calls); got != 1 {
			t.Errorf("code %d: attempts = %d, want 1 (no retry)", code, got)
		}
	}
}

func TestRetriesNetworkError(t *testing.T) {
	netErr := errors.New("connection reset by peer")
	stub := &stubRT{results: []result{
		{status: 0, err: netErr},
		{status: 0, err: netErr},
		{status: http.StatusOK},
	}}
	rt := New(stub, DefaultPolicy())
	noSleep(rt)

	resp, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
	if err != nil {
		t.Fatalf("unexpected error after recovery: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 3 {
		t.Errorf("attempts = %d, want 3", got)
	}
}

func TestNoRetryOnContextCanceled(t *testing.T) {
	// Transport returns a context.Canceled-wrapped error; it must not be retried.
	stub := &stubRT{results: []result{
		{status: 0, err: fmt.Errorf("Post: %w", context.Canceled)},
	}}
	rt := New(stub, DefaultPolicy())
	noSleep(rt)

	_, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if got := atomic.LoadInt32(&stub.calls); got != 1 {
		t.Errorf("attempts = %d, want 1 (canceled not retried)", got)
	}
}

func TestStopsWhenContextCanceledDuringBackoff(t *testing.T) {
	stub := &stubRT{results: []result{{status: 503}, {status: 503}, {status: 503}}}
	rt := New(stub, DefaultPolicy())
	// Sleep that cancels: simulates the context expiring during the backoff wait.
	ctx, cancel := context.WithCancel(context.Background())
	rt.sleep = func(c context.Context, _ time.Duration) error {
		cancel()
		return context.Canceled
	}
	resp, err := rt.RoundTrip(newReq(t, ctx, "x"))
	// One attempt happened (503), then backoff was cancelled -> return that 503.
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp == nil || resp.StatusCode != 503 {
		t.Errorf("want last 503 response surfaced after cancel, got %v / %v", resp, err)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 1 {
		t.Errorf("attempts = %d, want 1 before cancel", got)
	}
}

func TestHonorsRetryAfterSeconds(t *testing.T) {
	stub := &stubRT{results: []result{
		{status: 429, header: map[string]string{"Retry-After": "2"}},
		{status: http.StatusOK},
	}}
	rt := New(stub, DefaultPolicy())

	var slept time.Duration
	rt.sleep = func(ctx context.Context, d time.Duration) error { slept = d; return nil }

	resp, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if slept != 2*time.Second {
		t.Errorf("backoff = %v, want 2s from Retry-After", slept)
	}
}

func TestRetryAfterCappedAtMaxDelay(t *testing.T) {
	stub := &stubRT{results: []result{
		{status: 503, header: map[string]string{"Retry-After": "9999"}},
		{status: http.StatusOK},
	}}
	rt := New(stub, Policy{MaxRetries: 3, BaseDelay: time.Second, MaxDelay: 5 * time.Second})
	var slept time.Duration
	rt.sleep = func(ctx context.Context, d time.Duration) error { slept = d; return nil }

	if _, err := rt.RoundTrip(newReq(t, context.Background(), "x")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if slept != 5*time.Second {
		t.Errorf("backoff = %v, want capped at MaxDelay 5s", slept)
	}
}

func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 6, 10, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		in     string
		want   time.Duration
		wantOK bool
	}{
		{"", 0, false},
		{"5", 5 * time.Second, true},
		{"0", 0, true},
		{"-3", 0, true}, // negative seconds clamp to 0
		{"garbage", 0, false},
		{now.Add(10 * time.Second).UTC().Format(http.TimeFormat), 10 * time.Second, true},
		{now.Add(-10 * time.Second).UTC().Format(http.TimeFormat), 0, true}, // past date clamps to 0
	}
	for _, c := range cases {
		got, ok := parseRetryAfter(c.in, now)
		if ok != c.wantOK || got != c.want {
			t.Errorf("parseRetryAfter(%q) = (%v,%v), want (%v,%v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

func TestBackoffExponentialBounded(t *testing.T) {
	rt := New(&stubRT{}, Policy{MaxRetries: 10, BaseDelay: 100 * time.Millisecond, MaxDelay: time.Second})
	// Full jitter means each value is in [0, ceil]; ceil grows but is capped at
	// MaxDelay. Verify the upper bound holds across attempts.
	for attempt := 0; attempt < 12; attempt++ {
		d := rt.backoff(attempt, nil)
		if d < 0 || d > time.Second {
			t.Fatalf("attempt %d backoff = %v, want within [0, 1s]", attempt, d)
		}
	}
}

func TestZeroRetriesSingleAttempt(t *testing.T) {
	stub := &stubRT{results: []result{{status: 503}, {status: http.StatusOK}}}
	rt := New(stub, Policy{MaxRetries: 0})
	noSleep(rt)
	resp, err := rt.RoundTrip(newReq(t, context.Background(), "x"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 503 {
		t.Errorf("status = %d, want 503 (no retry)", resp.StatusCode)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 1 {
		t.Errorf("attempts = %d, want 1", got)
	}
}

// TestNonReplayableBodyNotRetried ensures a request whose body cannot be rewound
// (GetBody nil) is sent exactly once even on a retriable status.
func TestNonReplayableBodyNotRetried(t *testing.T) {
	stub := &stubRT{results: []result{{status: 503}, {status: http.StatusOK}}}
	rt := New(stub, DefaultPolicy())
	noSleep(rt)

	req, _ := http.NewRequest(http.MethodPost, "https://x.test", io.NopCloser(strings.NewReader("stream")))
	req.GetBody = nil // make it non-replayable
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != 503 {
		t.Errorf("status = %d, want 503 (non-replayable, no retry)", resp.StatusCode)
	}
	if got := atomic.LoadInt32(&stub.calls); got != 1 {
		t.Errorf("attempts = %d, want 1", got)
	}
}

func TestClientHelperWrapsTransport(t *testing.T) {
	stub := &stubRT{results: []result{{status: 503}, {status: http.StatusOK}}}
	hc := Client(&http.Client{Transport: stub}, DefaultPolicy())
	if _, ok := hc.Transport.(*RoundTripper); !ok {
		t.Fatalf("Client transport = %T, want *RoundTripper", hc.Transport)
	}
}
