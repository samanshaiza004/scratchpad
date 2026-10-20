package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const minimumMacOSVersion = "13.0"

// Environment-only deployment targets are not part of Go's cgo cache key.
// Put the target in compiler arguments as well, including Cargo's fingerprint.
func nativeCompilerEnv(goos string, env []string) []string {
	if goos != "darwin" {
		return env
	}
	env = setEnv(env, "MACOSX_DEPLOYMENT_TARGET", minimumMacOSVersion)
	flag := "-mmacosx-version-min=" + minimumMacOSVersion
	for _, key := range []string{"CGO_CFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS", "CFLAGS", "CXXFLAGS"} {
		value := envValue(env, key)
		if value == "" && strings.HasPrefix(key, "CGO_") && key != "CGO_LDFLAGS" {
			value = "-O2 -g"
		}
		env = setEnv(env, key, strings.TrimSpace(value+" "+flag))
	}
	if value := envValue(env, "CARGO_ENCODED_RUSTFLAGS"); value != "" {
		env = setEnv(env, "CARGO_ENCODED_RUSTFLAGS", value+"\x1f-C\x1flink-arg="+flag)
	} else {
		env = setEnv(env, "RUSTFLAGS", strings.TrimSpace(envValue(env, "RUSTFLAGS")+" -C link-arg="+flag))
	}
	return env
}

// Odin adds its macOS system library paths before extra -L flags. Give this
// invocation a private SDK view whose SDL binding names the selected library
// directly. All other SDK files are read through symlinks; the installed SDK
// and Alicorn source stay untouched.
func prepareMacSDLCompiler(out, odinExe string, env []string) ([]string, func(), error) {
	if env == nil {
		env = os.Environ()
	}
	cmd := exec.Command(odinExe, "root")
	cmd.Env = env
	output, err := cmd.Output()
	if err != nil {
		return nil, nil, fmt.Errorf("locate Odin SDK: %w", err)
	}
	sdk := strings.TrimSpace(string(output))
	prefix := envValue(env, "SDL3_PREFIX")
	if prefix == "" {
		return nil, nil, fmt.Errorf("macOS frontend build requires a selected SDL3_PREFIX")
	}
	library, err := filepath.Abs(filepath.Join(prefix, "lib", "libSDL3.dylib"))
	if err != nil {
		return nil, nil, err
	}
	if _, err := os.Stat(library); err != nil {
		return nil, nil, fmt.Errorf("selected SDL library: %w", err)
	}
	overlay, err := os.MkdirTemp(out, ".macos-odin-")
	if err != nil {
		return nil, nil, err
	}
	cleanup := func() { _ = os.RemoveAll(overlay) }
	for _, item := range []struct{ source, destination, except string }{
		{sdk, overlay, "vendor"},
		{filepath.Join(sdk, "vendor"), filepath.Join(overlay, "vendor"), "sdl3"},
		{filepath.Join(sdk, "vendor", "sdl3"), filepath.Join(overlay, "vendor", "sdl3"), "sdl3__foreign.odin"},
	} {
		if err := symlinkSDKEntries(item.source, item.destination, item.except); err != nil {
			cleanup()
			return nil, nil, err
		}
	}
	// A relative foreign import also works when the selected prefix contains
	// spaces (which Odin rejects in a source-level foreign import path).
	alias := filepath.Join(overlay, "vendor", "sdl3", "scratchpad-SDL3.dylib")
	if err := os.Symlink(library, alias); err != nil {
		cleanup()
		return nil, nil, err
	}
	binding := "package sdl3\n\n@(export) foreign import lib { \"scratchpad-SDL3.dylib\" }\n"
	if err := os.WriteFile(filepath.Join(overlay, "vendor", "sdl3", "sdl3__foreign.odin"), []byte(binding), 0o644); err != nil {
		cleanup()
		return nil, nil, err
	}
	canonicalLibrary, err := filepath.EvalSymlinks(library)
	if err != nil {
		cleanup()
		return nil, nil, err
	}
	hash, err := fileSHA256(canonicalLibrary)
	if err != nil {
		cleanup()
		return nil, nil, err
	}
	input := struct {
		Library             string `json:"library"`
		CanonicalLibrary    string `json:"canonicalLibrary"`
		LinkerInput         string `json:"linkerInput"`
		SHA256              string `json:"sha256"`
		MinimumMacOSVersion string `json:"minimumMacOSVersion"`
	}{library, canonicalLibrary, alias, hash, minimumMacOSVersion}
	data, err := json.MarshalIndent(input, "", "  ")
	if err != nil {
		cleanup()
		return nil, nil, err
	}
	if err := os.WriteFile(filepath.Join(out, "native-link-input.json"), append(data, '\n'), 0o644); err != nil {
		cleanup()
		return nil, nil, err
	}
	return setEnv(nativeCompilerEnv("darwin", env), "ODIN_ROOT", overlay), cleanup, nil
}

func symlinkSDKEntries(source, destination, except string) error {
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() == except {
			continue
		}
		if err := os.Symlink(filepath.Join(source, entry.Name()), filepath.Join(destination, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func runMacFrontendLink(root, out string, env []string, odinExe string, args []string) error {
	trace, err := os.Create(filepath.Join(out, "native-link-trace.txt"))
	if err != nil {
		return err
	}
	defer trace.Close()
	cmd := exec.Command(odinExe, args...)
	cmd.Dir, cmd.Env = root, env
	cmd.Stdout = io.MultiWriter(os.Stdout, trace)
	cmd.Stderr = io.MultiWriter(os.Stderr, trace)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("Odin frontend link: %w", err)
	}
	if err := trace.Sync(); err != nil {
		return err
	}
	data, err := os.ReadFile(trace.Name())
	if err != nil {
		return err
	}
	selected, err := filepath.EvalSymlinks(filepath.Join(envValue(env, "SDL3_PREFIX"), "lib", "libSDL3.dylib"))
	if err != nil {
		return err
	}
	found := false
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.Contains(filepath.Base(line), "SDL3") || !strings.HasSuffix(line, ".dylib") {
			continue
		}
		input, err := filepath.EvalSymlinks(line)
		if err != nil || input != selected {
			return fmt.Errorf("macOS linker loaded unexpected SDL input %s; selected %s", line, selected)
		}
		found = true
	}
	if !found {
		return fmt.Errorf("macOS link trace does not show the selected SDL input %s", selected)
	}
	return nil
}
