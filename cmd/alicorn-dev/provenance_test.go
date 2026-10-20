package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestMacCompilerInputsAreExplicitAndDoNotChangeOtherPlatforms(t *testing.T) {
	for _, original := range [][]string{
		{"RUSTFLAGS=-C opt-level=2", "CGO_CFLAGS=-O2 -DFIXTURE=1", "MACOSX_DEPLOYMENT_TARGET=27.0"},
		{"CARGO_ENCODED_RUSTFLAGS=-C\x1fopt-level=2"},
	} {
		for _, platform := range []string{"windows", "linux"} {
			if got := nativeCompilerEnv(platform, original); !reflect.DeepEqual(got, original) {
				t.Fatalf("%s compiler inputs changed: %v", platform, got)
			}
		}
		env := nativeCompilerEnv("darwin", append([]string{}, original...))
		if envValue(env, "MACOSX_DEPLOYMENT_TARGET") != "13.0" {
			t.Fatal("macOS target must be explicit")
		}
		for _, key := range []string{"CGO_CFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS", "CFLAGS", "CXXFLAGS"} {
			if !strings.Contains(envValue(env, key), "-mmacosx-version-min=13.0") {
				t.Fatalf("%s lacks a compiler/cache-visible target: %v", key, env)
			}
		}
		rust := envValue(env, "CARGO_ENCODED_RUSTFLAGS")
		if rust == "" {
			rust = envValue(env, "RUSTFLAGS")
		}
		if !strings.Contains(rust, "strip=none") || !strings.Contains(rust, "link-arg=-mmacosx-version-min=13.0") || !strings.Contains(rust, "opt-level=2") {
			t.Fatalf("macOS Rust inputs must preserve user flags, target the minimum OS and retain linker alignment: %q", rust)
		}
	}
}

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
