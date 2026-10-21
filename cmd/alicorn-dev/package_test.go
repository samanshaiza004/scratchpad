package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidPackageVersion(t *testing.T) {
	for _, version := range []string{"0.1.1", "1.0.0", "12.34.56"} {
		if !validPackageVersion(version) {
			t.Errorf("validPackageVersion(%q) = false", version)
		}
	}
	for _, version := range []string{"", "v0.1.1", "0.1", "0.1.1-beta", "01.2.3", "1..3", "1.2.3.4"} {
		if validPackageVersion(version) {
			t.Errorf("validPackageVersion(%q) = true", version)
		}
	}
}

func TestSafePackageOutputIsConfinedToOut(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "out"), 0o755); err != nil {
		t.Fatal(err)
	}

	inside := filepath.Join(root, "out", "packages", "windows")
	resolved, err := safePackageOutput(root, inside)
	if err != nil {
		t.Fatalf("safePackageOutput inside out: %v", err)
	}
	if resolved != inside {
		t.Fatalf("safePackageOutput = %q, want %q", resolved, inside)
	}

	for _, outside := range []string{
		filepath.Join(root, "out"),
		filepath.Join(root, "out-sibling", "package"),
		filepath.Join(root, "package"),
	} {
		if _, err := safePackageOutput(root, outside); err == nil {
			t.Errorf("safePackageOutput accepted outside path %q", outside)
		}
	}
}

func TestReadSDLSourceVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "SDL_version.h")
	header := "#define SDL_MAJOR_VERSION 3\n#define SDL_MINOR_VERSION 4\n#define SDL_MICRO_VERSION 18\n"
	if err := os.WriteFile(path, []byte(header), 0o644); err != nil {
		t.Fatal(err)
	}
	version, err := readSDLSourceVersion(path)
	if err != nil {
		t.Fatal(err)
	}
	if version != "3.4.18" {
		t.Fatalf("readSDLSourceVersion = %q, want 3.4.18", version)
	}
}

func TestGoToolchainLicensePath(t *testing.T) {
	root := t.TempDir()
	goroot := filepath.Join(root, "libexec")
	if err := os.Mkdir(goroot, 0o755); err != nil {
		t.Fatal(err)
	}
	license := filepath.Join(root, "LICENSE")
	if err := os.WriteFile(license, []byte("Go license"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := goToolchainLicensePath(goroot)
	if err != nil {
		t.Fatal(err)
	}
	if got != license {
		t.Fatalf("goToolchainLicensePath = %q, want parent license %q", got, license)
	}

	rootLicense := filepath.Join(goroot, "LICENSE")
	if err := os.WriteFile(rootLicense, []byte("GOROOT license"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err = goToolchainLicensePath(goroot)
	if err != nil {
		t.Fatal(err)
	}
	if got != rootLicense {
		t.Fatalf("goToolchainLicensePath = %q, want GOROOT license %q", got, rootLicense)
	}
}

func TestReadSDLPackageMetadata(t *testing.T) {
	path := filepath.Join(t.TempDir(), "alicorn-package.json")
	manifest := `{"host":{"sdlVersion":"3.4.18","sdlLinkage":"shared"}}`
	if err := os.WriteFile(path, []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	metadata, err := readSDLPackageMetadata(path)
	if err != nil {
		t.Fatal(err)
	}
	if metadata != (releaseSDL{Version: "3.4.18", Linkage: "shared"}) {
		t.Fatalf("readSDLPackageMetadata = %#v", metadata)
	}
	if err := os.WriteFile(path, []byte(`{"host":{}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readSDLPackageMetadata(path); err == nil {
		t.Fatal("readSDLPackageMetadata accepted a manifest without SDL metadata")
	}
}

func TestNativeFrontendEnvUsesProvidedSDLPrefix(t *testing.T) {
	prefix := t.TempDir()
	libDir := filepath.Join(prefix, "lib")
	if err := os.MkdirAll(libDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(libDir, "libSDL3.dylib"), []byte("runtime"), 0o644); err != nil {
		t.Fatal(err)
	}
	env, err := prepareNativeFrontendEnvWithPrefix([]string{"PATH=tools"}, prefix)
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(env, "LIBRARY_PATH"); got != libDir {
		t.Errorf("LIBRARY_PATH = %q, want %q", got, libDir)
	}
	if got := envValue(env, "DYLD_LIBRARY_PATH"); got != libDir {
		t.Errorf("DYLD_LIBRARY_PATH = %q, want %q", got, libDir)
	}
	if got := envValue(env, "SDL3_PREFIX"); got != prefix {
		t.Errorf("SDL3_PREFIX = %q, want %q", got, prefix)
	}
}

func TestNativePackageResourcesAvoidMacOSPackagerDuplicates(t *testing.T) {
	resources := []string{
		"licenses/AccessKit-LICENSE-APACHE.txt",
		"licenses/AccessKit-LICENSE-MIT.txt",
		"licenses/SDL-LICENSE.txt",
		"licenses/Atkinson-Hyperlegible-Next-OFL.txt",
		"licenses/Atkinson-Hyperlegible-Mono-OFL.txt",
		"licenses/Scratchpad-LICENSE.txt",
	}
	macOS := nativePackageResources("darwin", resources)
	wantMacOS := []string{
		"licenses/Atkinson-Hyperlegible-Next-OFL.txt",
		"licenses/Atkinson-Hyperlegible-Mono-OFL.txt",
		"licenses/Scratchpad-LICENSE.txt",
	}
	if len(macOS) != len(wantMacOS) {
		t.Fatalf("macOS generic resources = %v, want %v", macOS, wantMacOS)
	}
	for index, want := range wantMacOS {
		if macOS[index] != want {
			t.Fatalf("macOS generic resources = %v, want %v", macOS, wantMacOS)
		}
	}
	windows := nativePackageResources("windows", resources)
	if len(windows) != len(resources) {
		t.Fatalf("Windows generic resources = %v, want all staged license resources", windows)
	}
}

func TestPackageZipRoundTripAndRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "app")
	if err := os.MkdirAll(filepath.Join(source, "Resources"), 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"Scratchpad.exe":            "app executable",
		"Resources/SDL-LICENSE.txt": "license text",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(source, filepath.FromSlash(name)), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	archive := filepath.Join(root, "package.zip")
	if err := zipDirectory(source, archive, "Scratchpad"); err != nil {
		t.Fatal(err)
	}
	extracted := filepath.Join(root, "extracted")
	if err := unzipArchive(archive, extracted); err != nil {
		t.Fatal(err)
	}
	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(extracted, "Scratchpad", filepath.FromSlash(name)))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}

	traversalZip := filepath.Join(root, "traversal.zip")
	file, err := os.Create(traversalZip)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	entry, err := writer.Create("../outside.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("escape")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	err = unzipArchive(traversalZip, filepath.Join(root, "unsafe"))
	if err == nil || !strings.Contains(err.Error(), "unsafe path") {
		t.Fatalf("unzipArchive traversal error = %v, want unsafe path rejection", err)
	}
	if _, err := os.Stat(filepath.Join(root, "outside.txt")); !os.IsNotExist(err) {
		t.Fatalf("archive wrote outside extraction root: %v", err)
	}
}
