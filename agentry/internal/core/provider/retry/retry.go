// Package retry provides an http.RoundTripper that transparently retries
// transient HTTP failures with exponential backoff and jitter. It is shared by
// the provider adapters (anthropic, openaicompat) so a single rate-limit (429)
// or server blip (5xx), or a network error before any response, does not abort
// a whole model turn.
//
// Why this is safe for the POST requests the adapters issue: both adapters fully
// buffer the request body in a *bytes.Reader before calling the transport, so
// net/http populates Request.GetBody and the body is replayable. RoundTripper
// only retries when the body is replayable (GetBody != nil) or absent; a request
// whose body cannot be rewound is sent exactly once. Retries are likewise limited
// to status codes and transport errors that are genuinely transient and that a
// duplicate request cannot corrupt (rate limiting, request timeout, and 5xx).
//
// The streaming response body is never read here — RoundTripper returns as soon
// as it has a response with acceptable status, so the long-lived SSE stream is
// handed back to the caller untouched and is governed by the caller's context.
package retry

import (
	"context"
	"errors"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"sync"
	"time"
)

// Defaults for a Policy. Chosen to ride out brief rate-limit windows and server
// hiccups without making a hung backend wait pathologically long: with a 500ms
// base and 3 retries the worst-case added latency from backoff is on the order
// of a few seconds (plus any server-provided Retry-After).
const (
	DefaultMaxRetries = 3
	DefaultBaseDelay  = 500 * time.Millisecond
	DefaultMaxDelay   = 20 * time.Second
)

// Policy configures retry behavior. The zero value is not used directly; call
// DefaultPolicy and adjust, or construct one and rely on normalize() (applied by
// New) to fill non-positive fields with the defaults.
type Policy struct {
	// MaxRetries is the number of retries *after* the initial attempt. Zero
	// disables retrying (a single attempt is made).
	MaxRetries int
	// BaseDelay is the backoff for the first retry; it doubles each subsequent
	// retry up to MaxDelay (full jitter is then applied).
	BaseDelay time.Duration
	// MaxDelay caps the per-retry backoff before jitter.
	MaxDelay time.Duration
}

// DefaultPolicy returns the standard retry policy.
func DefaultPolicy() Policy {
	return Policy{
		MaxRetries: DefaultMaxRetries,
		BaseDelay:  DefaultBaseDelay,
		MaxDelay:   DefaultMaxDelay,
	}
}

// normalize fills non-positive fields with defaults so a partially-specified
// Policy is still well-formed. A negative MaxRetries is treated as zero.
func (p Policy) normalize() Policy {
	if p.MaxRetries < 0 {
		p.MaxRetries = 0
	}
	if p.BaseDelay <= 0 {
		p.BaseDelay = DefaultBaseDelay
	}
	if p.MaxDelay <= 0 {
		p.MaxDelay = DefaultMaxDelay
	}
	if p.MaxDelay < p.BaseDelay {
		p.MaxDelay = p.BaseDelay
	}
	return p
}

// RoundTripper wraps a base http.RoundTripper, adding retries for transient
// failures. It is safe for concurrent use.
type RoundTripper struct {
	base   http.RoundTripper
	policy Policy

	// sleep blocks for d or until ctx is done; overridable in tests so backoff
	// can be exercised without real time. Must return ctx.Err() when ctx fires.
	sleep func(ctx context.Context, d time.Duration) error

	mu   sync.Mutex
	rand *rand.Rand // guarded by mu; seeded per-RoundTripper for jitter
}

// New wraps base with retry behavior governed by policy. A nil base uses
// http.DefaultTransport. policy is normalized, so a partially-filled value is
// fine.
func New(base http.RoundTripper, policy Policy) *RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &RoundTripper{
		base:   base,
		policy: policy.normalize(),
		sleep:  sleepCtx,
		rand:   rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

// Client returns an *http.Client whose Transport is a RoundTripper wrapping
// base (or that client's existing transport / http.DefaultTransport). The
// returned client carries no Timeout: streaming turns are long-lived and are
// bounded by the request context, not a client deadline. Callers that need a
// header/dial safety net should set it on the base transport.
func Client(base *http.Client, policy Policy) *http.Client {
	var rt http.RoundTripper
	if base != nil {
		rt = base.Transport
	}
	return &http.Client{Transport: New(rt, policy)}
}

// RoundTrip implements http.RoundTripper.
func (rt *RoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	ctx := req.Context()
	// A request can only be safely replayed if its body is rewindable. Requests
	// with no body are trivially replayable.
	replayable := req.Body == nil || req.GetBody != nil

	var lastResp *http.Response
	var lastErr error

	for attempt := 0; ; attempt++ {
		// Honor cancellation before each attempt.
		if err := ctx.Err(); err != nil {
			if lastErr != nil {
				return nil, lastErr
			}
			return nil, err
		}

		// Build a fresh body for retries (the previous attempt consumed it).
		curReq := req
		if attempt > 0 && req.Body != nil {
			body, err := req.GetBody()
			if err != nil {
				// Cannot rewind — surface whatever we last had.
				if lastErr != nil {
					return nil, lastErr
				}
				return lastResp, nil
			}
			r2 := req.Clone(ctx)
			r2.Body = body
			curReq = r2
		}

		resp, err := rt.base.RoundTrip(curReq)
		lastResp, lastErr = resp, err

		retriable := rt.shouldRetry(resp, err)
		// Stop if we've exhausted retries, the result is acceptable, the request
		// is not replayable, or the context is gone.
		if !retriable || attempt >= rt.policy.MaxRetries || !replayable || ctx.Err() != nil {
			return resp, err
		}

		// We are going to retry: a failed-but-non-nil response body must be drained
		// and closed so the underlying connection can be reused and not leaked.
		delay := rt.backoff(attempt, resp)
		if resp != nil {
			drainAndClose(resp.Body)
		}

		if serr := rt.sleep(ctx, delay); serr != nil {
			// Context cancelled/expired during backoff: return the last real
			// outcome if we have one, else the cancellation error.
			if lastErr != nil {
				return nil, lastErr
			}
			if lastResp != nil {
				return lastResp, nil
			}
			return nil, serr
		}
	}
}

// shouldRetry reports whether the (resp, err) pair from one attempt is a
// transient failure worth retrying.
func (rt *RoundTripper) shouldRetry(resp *http.Response, err error) bool {
	if err != nil {
		// A context cancellation/deadline is intentional, never retry it.
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return false
		}
		// Any other transport-level error (connection reset, DNS, refused, EOF
		// before headers, ...) is treated as transient.
		return true
	}
	if resp == nil {
		return false
	}
	switch resp.StatusCode {
	case http.StatusRequestTimeout, // 408
		http.StatusTooEarly,            // 425
		http.StatusTooManyRequests,     // 429
		http.StatusInternalServerError, // 500
		http.StatusBadGateway,          // 502
		http.StatusServiceUnavailable,  // 503
		http.StatusGatewayTimeout:      // 504
		return true
	default:
		return false
	}
}

// backoff computes the delay before the next retry. When the server supplied a
// Retry-After header (on a 429/503), that value is honored (capped at MaxDelay).
// Otherwise it is exponential — BaseDelay * 2^attempt, capped at MaxDelay — with
// full jitter (a uniform pick in [0, capped]) to avoid synchronized retries.
func (rt *RoundTripper) backoff(attempt int, resp *http.Response) time.Duration {
	if resp != nil {
		if d, ok := parseRetryAfter(resp.Header.Get("Retry-After"), time.Now()); ok {
			if d > rt.policy.MaxDelay {
				d = rt.policy.MaxDelay
			}
			if d < 0 {
				d = 0
			}
			return d
		}
	}

	// Exponential ceiling with overflow guard.
	ceil := rt.policy.BaseDelay
	for i := 0; i < attempt; i++ {
		ceil *= 2
		if ceil >= rt.policy.MaxDelay || ceil <= 0 {
			ceil = rt.policy.MaxDelay
			break
		}
	}
	if ceil > rt.policy.MaxDelay {
		ceil = rt.policy.MaxDelay
	}

	// Full jitter in [0, ceil].
	rt.mu.Lock()
	j := rt.rand.Int63n(int64(ceil) + 1)
	rt.mu.Unlock()
	return time.Duration(j)
}

// parseRetryAfter interprets a Retry-After header value, which is either an
// integer number of seconds or an HTTP-date. now is injected for testability. It
// returns ok=false when the header is empty or unparseable.
func parseRetryAfter(v string, now time.Time) (time.Duration, bool) {
	if v == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(v); err == nil {
		if secs < 0 {
			secs = 0
		}
		return time.Duration(secs) * time.Second, true
	}
	if t, err := http.ParseTime(v); err == nil {
		// Measure against the supplied clock (callers pass time.Now()); falling
		// back to the wall clock only if a zero time was given.
		ref := now
		if ref.IsZero() {
			ref = time.Now()
		}
		d := t.Sub(ref)
		if d < 0 {
			d = 0
		}
		return d, true
	}
	return 0, false
}

// drainAndClose discards any remaining body bytes (bounded) and closes it, so a
// keep-alive connection from a retried-away response can be reused.
func drainAndClose(body io.ReadCloser) {
	if body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(body, 64<<10))
	_ = body.Close()
}

// sleepCtx blocks for d or until ctx is done, returning ctx.Err() on
// cancellation and nil when the full duration elapsed. A non-positive d returns
// immediately (still checking ctx).
func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			return nil
		}
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// compile-time assertion.
var _ http.RoundTripper = (*RoundTripper)(nil)
