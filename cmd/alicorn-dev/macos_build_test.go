//go:build darwin

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func writeNativeFixture(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMacFinalSignedManifest(t *testing.T) {
	appDir := t.TempDir()
	bundle := filepath.Join(appDir, "Scratchpad.app")
	exe := filepath.Join(bundle, "Contents", "MacOS", "Scratchpad")
	library := filepath.Join(bundle, "Contents", "Frameworks", "libfixture.dylib")
	source := filepath.Join(appDir, "fixture.c")
	writeNativeFixture(t, source, "int fixture(void) { return 42; } int main(void) { return 0; }\n")
	writeNativeFixture(t, filepath.Join(bundle, "Contents", "Resources", "notice.txt"), "fixture notice\n")
	writeNativeFixture(t, filepath.Join(bundle, "Contents", "Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Scratchpad</string><key>CFBundleIdentifier</key><string>test.scratchpad.package</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`)
	if err := os.MkdirAll(filepath.Dir(exe), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(library), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"-mmacosx-version-min=13.0", source, "-o", exe},
		{"-mmacosx-version-min=13.0", "-dynamiclib", source, "-o", library},
	} {
		if _, err := commandOutput(appDir, "clang", args...); err != nil {
			t.Fatal(err)
		}
	}
	// Force signing to change bytes even if the compiler already ad-hoc signed them.
	if _, err := commandOutput(appDir, "codesign", "--remove-signature", exe, library); err != nil {
		t.Fatal(err)
	}
	exeHash, _ := fileSHA256(exe)
	libraryHash, _ := fileSHA256(library)
	noticeHash, _ := fileSHA256(filepath.Join(bundle, "Contents", "Resources", "notice.txt"))
	metadata := map[string]any{
		"schema": 1,
		"application": map[string]any{"executable": "Contents/MacOS/Scratchpad", "sha256": exeHash,
			"resources": []any{map[string]any{"name": "Contents/Resources/notice.txt", "sha256": noticeHash}}},
		"dependencies": map[string]any{"bundled": []any{map[string]any{"name": "Contents/Frameworks/libfixture.dylib", "sha256": libraryHash}}},
		"host":         map[string]any{"alicornRevision": "candidate", "sdlVersion": macSDLVersion, "sdlLinkage": "shared"},
	}
	data, _ := json.Marshal(metadata)
	writeNativeFixture(t, filepath.Join(appDir, "alicorn-package.json"), string(data))
	writeNativeFixture(t, filepath.Join(bundle, "Contents", "Resources", "alicorn-package.json"), string(data))
	if err := signAndVerifyMacBundle(bundle); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(bundle, "Contents", "Resources", "alicorn-package.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &metadata); err != nil {
		t.Fatal(err)
	}
	app := metadata["application"].(map[string]any)
	if hash, exists := app["sha256"]; exists {
		t.Errorf("embedded main-executable hash %v creates a signing self-reference; final hash belongs in external release manifest", hash)
	}
	bundled := metadata["dependencies"].(map[string]any)["bundled"].([]any)
	entry := bundled[0].(map[string]any)
	finalHash, _ := fileSHA256(library)
	if entry["sha256"] != finalHash {
		t.Errorf("embedded library hash = %s, final signed bytes = %s", entry["sha256"], finalHash)
	}
	sidecar, err := os.ReadFile(filepath.Join(appDir, "alicorn-package.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(sidecar) != string(data) {
		t.Error("embedded and adjacent Alicorn manifests differ")
	}
	if _, err := commandOutput(appDir, "codesign", "--verify", "--deep", "--strict", bundle); err != nil {
		t.Fatal(err)
	}
}

// This opt-in test uses the same frontend build seam as the product, a real
// Odin vendor import, and a private SDL library with a distinctive symbol value.
// It must not be replaced with a DYLD_LIBRARY_PATH substitution.
func TestMacFrontendLinksSelectedSDL(t *testing.T) {
	if os.Getenv("SCRATCHPAD_NATIVE_BUILD_TESTS") != "1" {
		t.Skip("set SCRATCHPAD_NATIVE_BUILD_TESTS=1 for native compiler integration")
	}
	odin, err := exec.LookPath("odin")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	prefix := filepath.Join(root, "pinned SDL")
	library := filepath.Join(prefix, "lib", "libSDL3.dylib")
	writeNativeFixture(t, filepath.Join(root, "sdl.c"), "int SDL_GetVersion(void) { return 3004016; }\n")
	if err := os.MkdirAll(filepath.Dir(library), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := commandOutput(root, "clang", "-dynamiclib", "-mmacosx-version-min=13.0", filepath.Join(root, "sdl.c"), "-Wl,-install_name,"+library, "-o", library); err != nil {
		t.Fatal(err)
	}
	writeNativeFixture(t, filepath.Join(root, "frontends", "alicorn", "main.odin"), "package main\nimport sdl \"vendor:sdl3\"\nimport \"core:fmt\"\nmain :: proc() { fmt.println(sdl.GetVersion()) }\n")
	out := filepath.Join(root, "out")
	if err := os.MkdirAll(out, 0o755); err != nil {
		t.Fatal(err)
	}
	env, err := prepareNativeFrontendEnvWithPrefix(os.Environ(), prefix)
	if err != nil {
		t.Fatal(err)
	}
	exe, err := buildFrontend(root, out, odin, "-collection:alicorn="+root, "", false, false, env)
	if err != nil {
		t.Fatal(err)
	}
	imports, err := commandOutput(root, "otool", "-L", exe)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(imports), library) {
		t.Fatalf("frontend did not link selected SDL library %s:\n%s", library, imports)
	}
	cmd := exec.Command(exe)
	cmd.Env = unsetEnv(unsetEnv(os.Environ(), "DYLD_LIBRARY_PATH"), "DYLD_FALLBACK_LIBRARY_PATH")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("probe: %v: %s", err, output)
	}
	if strings.TrimSpace(string(output)) != "3004016" {
		t.Fatalf("linked SDL symbol returned %s", output)
	}
}

func TestMacBackendDeploymentTargetWithWarmCache(t *testing.T) {
	if os.Getenv("SCRATCHPAD_NATIVE_BUILD_TESTS") != "1" {
		t.Skip("set SCRATCHPAD_NATIVE_BUILD_TESTS=1 for native compiler integration")
	}
	root := t.TempDir()
	caliber := filepath.Join(root, "caliber")
	writeNativeFixture(t, filepath.Join(caliber, "Cargo.toml"), "[package]\nname = \"caliber-ffi\"\nversion = \"0.0.0\"\nedition = \"2021\"\n[lib]\ncrate-type = [\"cdylib\"]\n")
	writeNativeFixture(t, filepath.Join(caliber, "src", "lib.rs"), "#[no_mangle]\npub extern \"C\" fn caliber_fixture() -> i32 { std::env::var_os(\"SCRATCHPAD_MACOS_LINK_PROBE\").map(|s| s.len() as i32).unwrap_or(42) }\n")
	writeNativeFixture(t, filepath.Join(caliber, "include", "caliber.h"), "int caliber_fixture(void);\n")
	bridge := filepath.Join(root, "bridge", "caliber")
	writeNativeFixture(t, filepath.Join(bridge, "go.mod"), "module deployment-fixture\ngo 1.25.5\n")
	writeNativeFixture(t, filepath.Join(bridge, "cshared", "main.go"), `package main
/*
#cgo darwin LDFLAGS: -lcaliber_ffi -Wl,-rpath,@loader_path -Wl,-rpath,@executable_path
#include <caliber.h>
*/
import "C"
//export fixture
func fixture() C.int { return C.caliber_fixture() }
func main() {}
`)
	// The same cache sees a hostile host default and a later minimum-OS change.
	// The driver must encode the supported target in every compiler's inputs.
	t.Setenv("GOCACHE", filepath.Join(root, "go-cache"))
	t.Setenv("CGO_CFLAGS", "-O2 -DFIXTURE=1")
	t.Setenv("CGO_CXXFLAGS", "-O2 -DFIXTURE=1")
	for _, hostDefault := range []string{"27.0", "13.0"} {
		t.Setenv("MACOSX_DEPLOYMENT_TARGET", hostDefault)
		out := filepath.Join(root, "out")
		env, library, err := buildCaliberAndBackend(root, caliber, "go", out, true)
		if err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"CGO_CFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS"} {
			if !strings.Contains(envValue(env, key), "-mmacosx-version-min=13.0") {
				t.Errorf("host target %s: %s = %q lacks a cache-key-visible macOS 13 target", hostDefault, key, envValue(env, key))
			}
		}
		for _, image := range []string{library, filepath.Join(out, backendLibraryName())} {
			if err := verifyDarwinLinkeditAlignment(image); err != nil {
				t.Fatal(err)
			}
			commands, err := commandOutput(root, "otool", "-l", image)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(commands), "minos 13.0") {
				t.Errorf("host target %s: %s does not target 13.0:\n%s", hostDefault, image, commands)
			}
		}
	}
}
