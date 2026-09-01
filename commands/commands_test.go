package commands

import "testing"

func TestInitialVocabularyIsStableAndUnified(t *testing.T) {
	if len(InitialVocabulary) != 35 {
		t.Fatalf("got %d commands, want 35", len(InitialVocabulary))
	}
	seen := map[ID]bool{}
	for _, id := range InitialVocabulary {
		if seen[id] {
			t.Fatalf("duplicate command %q", id)
		}
		seen[id] = true
	}
}
