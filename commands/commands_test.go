package commands

import "testing"

func TestInitialVocabularyIsStableAndUnified(t *testing.T) {
	if len(InitialVocabulary) != 22 {
		t.Fatalf("got %d commands, want 16", len(InitialVocabulary))
	}
	seen := map[ID]bool{}
	for _, id := range InitialVocabulary {
		if seen[id] {
			t.Fatalf("duplicate command %q", id)
		}
		seen[id] = true
	}
}
