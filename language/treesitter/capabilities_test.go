package treesitter

import "testing"

func TestCapabilitiesAreInternallyConsistent(t *testing.T) {
	caps := Capabilities()
	switch caps.Backend {
	case BackendOfficial:
		if !caps.Go || !caps.TypeScript || !caps.TSX {
			t.Fatalf("official capabilities = %+v", caps)
		}
		if err := RequireOfficial(); err != nil {
			t.Fatal(err)
		}
	case BackendPure:
		if !caps.Go || caps.TypeScript || caps.TSX {
			t.Fatalf("pure capabilities = %+v", caps)
		}
		if err := RequireOfficial(); err == nil {
			t.Fatal("pure backend unexpectedly satisfies official release requirements")
		}
	case BackendNone:
		if caps.Go || caps.TypeScript || caps.TSX {
			t.Fatalf("none capabilities = %+v", caps)
		}
		if err := RequireOfficial(); err == nil {
			t.Fatal("disabled backend unexpectedly satisfies official release requirements")
		}
	default:
		t.Fatalf("unknown backend %q", caps.Backend)
	}
}
