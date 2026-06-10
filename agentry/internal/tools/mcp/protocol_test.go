package mcp

import "testing"

// TestNegotiateProtocolVersion exercises the server-side MCP version-negotiation
// rule: a supported requested version is echoed back verbatim; anything else
// (unknown, malformed, or empty) falls back to the preferred ProtocolVersion.
func TestNegotiateProtocolVersion(t *testing.T) {
	cases := []struct {
		name      string
		requested string
		want      string
	}{
		{"empty falls back to preferred", "", ProtocolVersion},
		{"preferred echoes itself", ProtocolVersion, ProtocolVersion},
		{"newer supported is echoed", "2025-03-26", "2025-03-26"},
		{"newest supported is echoed", "2025-06-18", "2025-06-18"},
		{"unknown future falls back", "2099-01-01", ProtocolVersion},
		{"garbage falls back", "not-a-version", ProtocolVersion},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := NegotiateProtocolVersion(tc.requested); got != tc.want {
				t.Errorf("NegotiateProtocolVersion(%q) = %q, want %q", tc.requested, got, tc.want)
			}
		})
	}
}

// TestSupportedProtocolVersionsIncludePreferred guards the invariant that the
// preferred ProtocolVersion is itself a member of the supported set — otherwise
// a client that requested exactly our preferred version would not get it echoed.
func TestSupportedProtocolVersionsIncludePreferred(t *testing.T) {
	found := false
	for _, v := range SupportedProtocolVersions {
		if v == ProtocolVersion {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("ProtocolVersion %q is not in SupportedProtocolVersions %v", ProtocolVersion, SupportedProtocolVersions)
	}
}

// TestNegotiateAllSupportedEchoBack ensures every advertised supported version
// round-trips through negotiation unchanged, so adding a revision to the list is
// enough to make the server accept it.
func TestNegotiateAllSupportedEchoBack(t *testing.T) {
	for _, v := range SupportedProtocolVersions {
		if got := NegotiateProtocolVersion(v); got != v {
			t.Errorf("supported version %q negotiated to %q, want echo", v, got)
		}
	}
}
