package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateWindowsStaticLinkRecipe(t *testing.T) {
	recipe, odin := validWindowsStaticLinkRecipe(t)
	if err := validateWindowsStaticLinkRecipe(recipe, odin); err != nil {
		t.Fatalf("valid static-link recipe rejected: %v", err)
	}

	badHash := recipe
	badHash.Artifacts.SDL.SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
	if err := validateWindowsStaticLinkRecipe(badHash, odin); err == nil {
		t.Fatal("recipe with a corrupted SDL artifact hash was accepted")
	}

	wrongOdin := recipe
	wrongOdin.Odin.Executable = filepath.Join(t.TempDir(), "other-odin.exe")
	if err := validateWindowsStaticLinkRecipe(wrongOdin, odin); err == nil {
		t.Fatal("recipe for a different Odin executable was accepted")
	}
}

func validWindowsStaticLinkRecipe(t *testing.T) (windowsStaticLinkRecipe, string) {
	t.Helper()
	root := t.TempDir()
	odinRoot := filepath.Join(root, "prepared odin")
	sdlLibrary := filepath.Join(odinRoot, "vendor", "sdl3", "SDL3.lib")
	accessKitLibrary := filepath.Join(root, "accesskit", "accesskit.lib")
	manifest := filepath.Join(root, "manifest.json")
	sdlLicense := filepath.Join(root, "SDL-LICENSE.txt")
	accessKitApache := filepath.Join(root, "AccessKit-LICENSE-APACHE.txt")
	accessKitMIT := filepath.Join(root, "AccessKit-LICENSE-MIT.txt")
	odin := filepath.Join(root, "odin.exe")
	for path, content := range map[string]string{
		sdlLibrary:       "static SDL archive",
		accessKitLibrary: "static AccessKit archive",
		manifest:         "{}",
		sdlLicense:       "SDL license",
		accessKitApache:  "Apache license",
		accessKitMIT:     "MIT license",
		odin:             "compiler",
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	recipe := windowsStaticLinkRecipe{
		SchemaVersion: 1,
		Target:        "windows-x86_64-msvc",
		Linkage:       "static",
		Odin: struct {
			Executable        string   `json:"executable"`
			CompilerArguments []string `json:"compilerArguments"`
		}{Executable: odin, CompilerArguments: []string{"-extra-linker-flags:/LIBPATH:\"C:/path with spaces\" SDL3.lib"}},
	}
	recipe.Environment.ODINRoot = odinRoot
	recipe.Artifacts.SDL.Version = "3.4.16"
	recipe.Artifacts.SDL.Library = sdlLibrary
	recipe.Artifacts.SDL.SHA256, _ = fileSHA256(sdlLibrary)
	recipe.Artifacts.SDL.License = sdlLicense
	recipe.Artifacts.AccessKit.Library = accessKitLibrary
	recipe.Artifacts.AccessKit.SHA256, _ = fileSHA256(accessKitLibrary)
	recipe.Artifacts.AccessKit.Licenses = []string{accessKitApache, accessKitMIT}
	recipe.Provenance.Fingerprint = "a1b2c3"
	recipe.Provenance.Manifest = manifest
	return recipe, odin
}
