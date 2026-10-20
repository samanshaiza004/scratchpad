package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPackageSourceRecordsSelectedCheckouts(t *testing.T) {
	root, alicorn, caliber := t.TempDir(), t.TempDir(), t.TempDir()
	var revisions []string
	for i, dir := range []string{root, alicorn, caliber} {
		for _, args := range [][]string{
			{"init", "--quiet", dir},
			{"-C", dir, "-c", "user.name=Package Test", "-c", "user.email=package@example.invalid", "commit", "--quiet", "--allow-empty", "-m", []string{"Scratchpad", "Alicorn candidate", "Caliber candidate"}[i]},
		} {
			if _, err := commandOutput(root, "git", args...); err != nil {
				t.Fatal(err)
			}
		}
		revision, err := gitOutput(dir, "rev-parse", "HEAD")
		if err != nil {
			t.Fatal(err)
		}
		revisions = append(revisions, strings.TrimSpace(revision))
	}
	lock := lockFile{Schema: 1,
		Alicorn: dependency{Repository: "alicorn", Ref: "main", Revision: strings.Repeat("a", 40)},
		Caliber: dependency{Repository: "caliber", Ref: "main", Revision: strings.Repeat("c", 40)},
	}
	data, _ := json.Marshal(lock)
	if err := os.WriteFile(filepath.Join(root, "dependencies.lock.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
	source, err := packageSource(root, alicorn, caliber)
	if err != nil {
		t.Fatal(err)
	}
	want := releaseSource{Scratchpad: revisions[0], Alicorn: revisions[1], Caliber: revisions[2]}
	if source != want {
		t.Fatalf("package source = %+v, want actual selected checkouts %+v (lock is intentionally different)", source, want)
	}
	manifest := scratchpadBuildManifest{Schema: 1, Source: source}
	appDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(appDir, "Scratchpad.app", "Contents", "Resources"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writePackageBuildManifest(appDir, manifest); err != nil {
		t.Fatal(err)
	}
	if makeReleaseManifest(manifest, nil).Source != want {
		t.Fatal("release manifest lost selected source identity")
	}
	if _, err := packageSource(root, filepath.Join(root, "missing-alicorn"), caliber); err == nil {
		t.Fatal("missing selected checkout was silently replaced by lock provenance")
	}
}
