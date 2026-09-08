package language

import "testing"

func TestDefaultRegistryRegistersCommandCapabilities(t *testing.T) {
	registry := DefaultRegistry()
	for _, id := range []ID{Go, JavaScript, TypeScript, TSX} {
		provider, ok := registry.Lookup(id)
		if !ok || provider.LineComment != "//" || !provider.SupportsCommentToggle {
			t.Fatalf("provider %q = %#v, %v", id, provider, ok)
		}
	}
	if registry.SupportsCommentToggle(Rust) {
		t.Fatal("Rust comment toggle should remain outside the first proof")
	}
}
