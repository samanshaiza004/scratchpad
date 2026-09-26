// alicorn-dev is the bounded build/test/smoke harness for Scratchpad's
// experimental Odin/Alicorn frontend. The Go application and c-shared bridge
// remain the same frontend-neutral implementation used by GPUI.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type dependency struct {
	Repository string `json:"repository"`
	Ref        string `json:"ref"`
	Revision   string `json:"revision"`
}

type lockFile struct {
	Schema  uint32     `json:"schema"`
	Caliber dependency `json:"caliber"`
	Alicorn dependency `json:"alicorn"`
}

type artifactManifest struct {
	CaliberCommit string   `json:"caliber_commit"`
	AlicornCommit string   `json:"alicorn_commit"`
	ABIVersion    uint32   `json:"abi_version"`
	Artifacts     []string `json:"artifacts"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "alicorn-dev:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: go run ./cmd/alicorn-dev <build|test|smoke|run> [options]")
	}
	command := args[0]
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	goPath := flags.String("go", os.Getenv("SCRATCHPAD_GO"), "64-bit Go executable (Windows cgo requires amd64)")
	odinArg := flags.String("odin", "", "Odin compiler (or use ALICORN_ODIN/PATH)")
	alicornRootArg := flags.String("alicorn-root", os.Getenv("CALIBER_CANDIDATE_ROOT"), "Alicorn checkout override for dependency validation")
	allowAlicornRevision := flags.Bool("allow-alicorn-revision", false, "allow an Alicorn candidate different from the lock")
	release := flags.Bool("release", false, "build optimized native artifacts")
	outArg := flags.String("out", "out/alicorn", "artifact directory")
	workspace := flags.String("workspace", "", "initial Scratchpad workspace directory; defaults to this checkout")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if len(flags.Args()) != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if command != "build" && command != "test" && command != "smoke" && command != "run" {
		return fmt.Errorf("unknown command %q; expected build, test, smoke, or run", command)
	}

	root, err := repoRoot()
	if err != nil {
		return err
	}
	goExe, err := resolveGo(*goPath)
	if err != nil {
		return err
	}
	odinExe, err := resolveOdin(*odinArg)
	if err != nil {
		return err
	}
	if err := validateTools(root, goExe, odinExe); err != nil {
		return err
	}
	locked, err := readLock(root)
	if err != nil {
		return err
	}
	alicornRoot := *alicornRootArg
	if alicornRoot == "" {
		alicornRoot = filepath.Join(root, ".deps", "alicorn")
	}
	alicornRoot, err = filepath.Abs(alicornRoot)
	if err != nil {
		return err
	}
	alicornCommit, err := gitOutput(alicornRoot, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("inspect Alicorn checkout at %s: %w", alicornRoot, err)
	}
	alicornCommit = strings.TrimSpace(alicornCommit)
	if !*allowAlicornRevision && alicornCommit != locked.Alicorn.Revision {
		return fmt.Errorf("Alicorn checkout is at %s; dependencies.lock.json requires %s", alicornCommit, locked.Alicorn.Revision)
	}
	if _, err := os.Stat(filepath.Join(alicornRoot, "runtime")); err != nil {
		return fmt.Errorf("Alicorn runtime source is missing from %s: %w", alicornRoot, err)
	}
	caliberRoot := filepath.Join(root, ".deps", "caliber")
	caliberCommit, err := gitOutput(caliberRoot, "rev-parse", "HEAD")
	if err != nil {
		return fmt.Errorf("inspect locked Caliber checkout: %w", err)
	}
	caliberCommit = strings.TrimSpace(caliberCommit)
	if caliberCommit != locked.Caliber.Revision {
		return fmt.Errorf("Caliber checkout is at %s; dependencies.lock.json requires %s", caliberCommit, locked.Caliber.Revision)
	}
	if _, err := os.Stat(filepath.Join(caliberRoot, "include", "caliber.h")); err != nil {
		return fmt.Errorf("canonical Caliber header is missing: %w", err)
	}

	out := *outArg
	if !filepath.IsAbs(out) {
		out = filepath.Join(root, out)
	}
	out, err = filepath.Abs(out)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	env, caliberLibrary, err := buildCaliberAndBackend(root, caliberRoot, goExe, out, *release)
	if err != nil {
		return err
	}
	if err := stageCaliberLibrary(caliberLibrary, out); err != nil {
		return err
	}
	backendPath := filepath.Join(out, backendLibraryName())
	manifest := artifactManifest{
		CaliberCommit: locked.Caliber.Revision,
		AlicornCommit: alicornCommit,
		ABIVersion:    1,
		Artifacts:     []string{backendLibraryName(), filepath.Base(caliberLibrary)},
	}
	if err := writeManifest(out, manifest); err != nil {
		return err
	}
	collectionArg := "-collection:alicorn=" + filepath.ToSlash(alicornRoot)

	switch command {
	case "build":
		frontendEnv, err := prepareNativeFrontendEnv(root, env)
		if err != nil {
			return err
		}
		exe, err := buildFrontend(root, out, odinExe, collectionArg, *release, frontendEnv)
		if err != nil {
			return err
		}
		manifest.Artifacts = append(manifest.Artifacts, filepath.Base(exe))
		return writeManifest(out, manifest)
	case "test":
		if err := runGoTests(root, goExe, env); err != nil {
			return err
		}
		if err := runCommand(root, nil, "odin", odinExe, "check", filepath.Join(root, "frontends", "alicorn"), collectionArg); err != nil {
			return fmt.Errorf("Alicorn frontend type check: %w", err)
		}
		testEnv := setEnv(env, "SCRATCHPAD_BACKEND_LIBRARY", backendPath)
		testEnv = setRuntimePath(testEnv, out)
		testExe := filepath.Join(out, "scratchpad-alicorn-bridge-tests"+exeSuffix())
		if err := runCommand(root, testEnv, "odin", odinExe, "test", filepath.Join(root, "frontends", "alicorn", "bridge"), "-out:"+testExe); err != nil {
			return fmt.Errorf("Alicorn Caliber bridge/lifecycle tests: %w", err)
		}
		return nil
	case "run", "smoke":
		frontendEnv, err := prepareNativeFrontendEnv(root, env)
		if err != nil {
			return err
		}
		exe, err := buildFrontend(root, out, odinExe, collectionArg, *release, frontendEnv)
		if err != nil {
			return err
		}
		manifest.Artifacts = append(manifest.Artifacts, filepath.Base(exe))
		if err := writeManifest(out, manifest); err != nil {
			return err
		}
		workspacePath := *workspace
		if workspacePath == "" {
			workspacePath = root
		}
		launchEnv := setEnv(frontendEnv, "SCRATCHPAD_BACKEND_LIBRARY", backendPath)
		launchEnv = setRuntimePath(launchEnv, out)
		launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_WORKSPACE", workspacePath)
		if command == "smoke" {
			if runtime.GOOS == "linux" && os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
				return errors.New("native smoke skipped: Linux has no DISPLAY/WAYLAND_DISPLAY; use `test` for headless foreign/type checks")
			}
			launchEnv = setEnv(launchEnv, "SCRATCHPAD_ALICORN_SMOKE", "1")
			return runCommandWithTimeout(root, launchEnv, 15*time.Second, exe)
		}
		return runCommand(root, launchEnv, "Alicorn frontend", exe)
	}
	return nil
}

func repoRoot() (string, error) {
	output, err := commandOutput(".", "git", "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func readLock(root string) (lockFile, error) {
	data, err := os.ReadFile(filepath.Join(root, "dependencies.lock.json"))
	if err != nil {
		return lockFile{}, err
	}
	var lock lockFile
	if err := json.Unmarshal(data, &lock); err != nil {
		return lockFile{}, fmt.Errorf("parse dependencies.lock.json: %w", err)
	}
	if lock.Schema != 1 || !validRevision(lock.Caliber.Revision) || !validRevision(lock.Alicorn.Revision) {
		return lockFile{}, errors.New("dependencies.lock.json must contain exact Caliber and Alicorn commit revisions")
	}
	if lock.Alicorn.Repository == "" || lock.Alicorn.Ref == "" || lock.Caliber.Repository == "" {
		return lockFile{}, errors.New("dependencies.lock.json is missing dependency repository/ref metadata")
	}
	return lock, nil
}

func validRevision(value string) bool {
	if len(value) != 40 {
		return false
	}
	for _, r := range value {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

func resolveGo(requested string) (string, error) {
	if requested == "" {
		requested = "go"
	}
	resolved, err := exec.LookPath(requested)
	if err != nil {
		if filepath.IsAbs(requested) {
			return "", fmt.Errorf("Go executable not found: %s", requested)
		}
		return "", errors.New("Go was not found; install Go and add it to PATH, or pass --go PATH")
	}
	return filepath.Abs(resolved)
}

func resolveOdin(requested string) (string, error) {
	if requested == "" {
		requested = os.Getenv("ALICORN_ODIN")
	}
	if requested == "" {
		requested = "odin"
	}
	resolved, err := exec.LookPath(requested)
	if err != nil {
		if filepath.IsAbs(requested) || strings.ContainsRune(requested, filepath.Separator) {
			return "", fmt.Errorf("Odin executable not found: %s", requested)
		}
		return "", errors.New("Odin was not found; install Odin and add it to PATH, or pass --odin PATH / set ALICORN_ODIN")
	}
	return filepath.Abs(resolved)
}

func validateTools(root, goExe, odinExe string) error {
	for _, name := range []string{"cargo", "rustc"} {
		if _, err := exec.LookPath(name); err != nil {
			return fmt.Errorf("%s is required to build locked Caliber; install the Rust toolchain", name)
		}
	}
	goHostArch, err := commandOutput(root, goExe, "env", "GOHOSTARCH")
	if err != nil {
		return fmt.Errorf("inspect Go host architecture: %w", err)
	}
	goArch, err := commandOutput(root, goExe, "env", "GOARCH")
	if err != nil {
		return fmt.Errorf("inspect Go target architecture: %w", err)
	}
	cgo, err := commandOutput(root, goExe, "env", "CGO_ENABLED")
	if err != nil {
		return fmt.Errorf("inspect Go cgo setting: %w", err)
	}
	if runtime.GOOS == "windows" && (strings.TrimSpace(string(goHostArch)) != "amd64" || strings.TrimSpace(string(goArch)) != "amd64") {
		return fmt.Errorf("Windows Alicorn requires 64-bit Go and cgo (GOHOSTARCH=amd64 and GOARCH=amd64); selected %s (host) / %s (target). Install 64-bit Go or pass -Go/--go PATH", strings.TrimSpace(string(goHostArch)), strings.TrimSpace(string(goArch)))
	}
	if strings.TrimSpace(string(cgo)) != "1" {
		return errors.New("CGO_ENABLED must be 1 to build the shared Scratchpad backend")
	}
	if runtime.GOOS == "windows" {
		cc, err := commandOutput(root, goExe, "env", "CC")
		if err != nil {
			return fmt.Errorf("inspect cgo compiler: %w", err)
		}
		machine, err := commandOutput(root, strings.TrimSpace(string(cc)), "-dumpmachine")
		if err != nil {
			return fmt.Errorf("Windows cgo needs a working 64-bit MinGW-w64 GCC; check `go env CC`: %w", err)
		}
		if !strings.Contains(strings.ToLower(string(machine)), "x86_64") {
			return fmt.Errorf("Windows cgo compiler must target x86_64; %q reports %q", strings.TrimSpace(string(cc)), strings.TrimSpace(string(machine)))
		}
	}
	if _, err := commandOutput(root, odinExe, "version"); err != nil {
		return fmt.Errorf("Odin compiler did not run: %w", err)
	}
	return nil
}

func buildCaliberAndBackend(root, caliberRoot, goExe, out string, release bool) ([]string, string, error) {
	caliberTarget := filepath.Join(root, "frontends", "alicorn", "build", "caliber-target")
	cargoArgs := []string{"build", "-p", "caliber-ffi", "--lib", "--target-dir", caliberTarget}
	if release {
		cargoArgs = append(cargoArgs, "--release")
	}
	if err := runCommand(caliberRoot, nil, "cargo", "cargo", cargoArgs...); err != nil {
		return nil, "", err
	}
	caliberLibrary := caliberLibraryFromTarget(caliberTarget, release)
	if _, err := os.Stat(caliberLibrary); err != nil {
		return nil, "", fmt.Errorf("locked Caliber library was not produced at %s: %w", caliberLibrary, err)
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return nil, "", err
	}
	backend := filepath.Join(out, backendLibraryName())
	backendDir := filepath.Join(root, "bridge", "caliber")
	goEnv := os.Environ()
	goEnv = setEnv(goEnv, "CGO_ENABLED", "1")
	goEnv = setEnv(goEnv, "CALIBER_ROOT", caliberRoot)
	goEnv = setEnv(goEnv, "CGO_CFLAGS", strings.TrimSpace(os.Getenv("CGO_CFLAGS")+" -I"+filepath.ToSlash(filepath.Join(caliberRoot, "include"))))
	goEnv = setEnv(goEnv, "CGO_LDFLAGS", "-L"+filepath.Dir(caliberLibrary))
	goEnv = setEnv(goEnv, "CGO_LDFLAGS_ALLOW", `-L.*|-l.*|-Wl,-rpath,.*`)
	goEnv = setRuntimePath(goEnv, filepath.Dir(caliberLibrary))
	goArgs := []string{"build", "-buildmode=c-shared", "-o", backend}
	if release {
		goArgs = append(goArgs, "-ldflags", "-s -w")
	}
	goArgs = append(goArgs, "./cshared")
	if err := runCommandWithEnv(backendDir, goEnv, "Go", goExe, goArgs...); err != nil {
		return nil, "", fmt.Errorf("build existing scratchpad_backend_* c-shared library: %w", err)
	}
	caliberCopy := filepath.Join(out, filepath.Base(caliberLibrary))
	if err := copyFile(caliberLibrary, caliberCopy); err != nil {
		return nil, "", err
	}
	if runtime.GOOS == "darwin" {
		if err := relocateDarwinCaliber(caliberLibrary, caliberCopy, backend); err != nil {
			return nil, "", err
		}
	}
	return goEnv, caliberLibrary, nil
}

func runGoTests(root, goExe string, env []string) error {
	if err := runCommandWithEnv(root, env, "Go", goExe, "test", "-tags", "treesitter_release", "./..."); err != nil {
		return fmt.Errorf("Scratchpad root Go tests: %w", err)
	}
	bridgeDir := filepath.Join(root, "bridge", "caliber")
	if err := runCommandWithEnv(bridgeDir, env, "Go", goExe, "test", "./..."); err != nil {
		return fmt.Errorf("frontend-neutral Caliber bridge tests: %w", err)
	}
	return nil
}

func prepareNativeFrontendEnv(root string, env []string) ([]string, error) {
	if runtime.GOOS != "darwin" {
		return env, nil
	}
	prefix, err := commandOutput(root, "brew", "--prefix", "sdl3")
	if err != nil {
		return nil, fmt.Errorf("locate SDL3 installed by Homebrew (install it with `brew install sdl3`): %w", err)
	}
	libDir := filepath.Join(strings.TrimSpace(string(prefix)), "lib")
	if _, err := os.Stat(filepath.Join(libDir, "libSDL3.dylib")); err != nil {
		return nil, fmt.Errorf("SDL3 shared library was not found under %s; install it with `brew install sdl3`: %w", libDir, err)
	}
	env = prependPathEnv(env, "LIBRARY_PATH", libDir)
	env = prependPathEnv(env, "DYLD_LIBRARY_PATH", libDir)
	return env, nil
}

func prependPathEnv(env []string, key, directory string) []string {
	existing := envValue(env, key)
	if existing == "" {
		return setEnv(env, key, directory)
	}
	for _, part := range filepath.SplitList(existing) {
		if part == directory {
			return env
		}
	}
	return setEnv(env, key, directory+string(os.PathListSeparator)+existing)
}

func envValue(env []string, key string) string {
	prefix := key + "="
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}
	return ""
}

func buildFrontend(root, out, odinExe, collectionArg string, release bool, env []string) (string, error) {
	if runtime.GOOS == "windows" {
		sdl := filepath.Join(filepath.Dir(odinExe), "vendor", "sdl3", "SDL3.dll")
		if info, err := os.Stat(sdl); err != nil || info.Size() < 100_000 {
			return "", fmt.Errorf("a real Odin distribution with vendor/sdl3/SDL3.dll is required (missing or invalid: %s)", sdl)
		}
		if err := copyFile(sdl, filepath.Join(out, "SDL3.dll")); err != nil {
			return "", err
		}
	}
	args := []string{"build", filepath.Join(root, "frontends", "alicorn"), "-out:" + filepath.Join(out, "scratchpad-alicorn"+exeSuffix()), collectionArg}
	if release {
		args = append(args, "-o:speed")
	}
	if err := runCommand(root, env, "odin", odinExe, args...); err != nil {
		return "", fmt.Errorf("build Scratchpad Alicorn frontend: %w", err)
	}
	return filepath.Join(out, "scratchpad-alicorn"+exeSuffix()), nil
}

func stageCaliberLibrary(caliberLibrary, out string) error {
	copyPath := filepath.Join(out, filepath.Base(caliberLibrary))
	if _, err := os.Stat(copyPath); err == nil {
		return nil
	}
	if err := copyFile(caliberLibrary, copyPath); err != nil {
		return err
	}
	if runtime.GOOS == "darwin" {
		return runCommand(".", nil, "install_name_tool", "install_name_tool", "-id", "@rpath/libcaliber_ffi.dylib", copyPath)
	}
	return nil
}

func relocateDarwinCaliber(source, copyPath, backend string) error {
	if err := runCommand(".", nil, "install_name_tool", "install_name_tool", "-id", "@rpath/libcaliber_ffi.dylib", copyPath); err != nil {
		return err
	}
	encoded := filepath.Join(filepath.Dir(source), "deps", filepath.Base(source))
	return runCommand(".", nil, "install_name_tool", "install_name_tool", "-change", encoded, "@rpath/libcaliber_ffi.dylib", backend)
}

func writeManifest(out string, manifest artifactManifest) error {
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "artifact-manifest.json"), append(data, '\n'), 0o644)
}

func caliberLibraryFromTarget(targetDir string, release bool) string {
	name := "libcaliber_ffi.so"
	if runtime.GOOS == "darwin" {
		name = "libcaliber_ffi.dylib"
	} else if runtime.GOOS == "windows" {
		name = "caliber_ffi.dll"
	}
	profile := "debug"
	if release {
		profile = "release"
	}
	return filepath.Join(targetDir, profile, name)
}

func backendLibraryName() string {
	switch runtime.GOOS {
	case "darwin":
		return "libscratchpad_backend.dylib"
	case "windows":
		return "scratchpad_backend.dll"
	default:
		return "libscratchpad_backend.so"
	}
}

func exeSuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func copyFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(destination, data, 0o755)
}

func commandOutput(dir, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func gitOutput(dir string, args ...string) (string, error) {
	output, err := commandOutput(dir, "git", args...)
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func runCommand(dir string, env []string, label, name string, args ...string) error {
	return runCommandWithEnv(dir, env, label, name, args...)
}

func runCommandWithEnv(dir string, env []string, label, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = env
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	start := time.Now()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s failed after %s: %w", label, strings.Join(args, " "), time.Since(start).Round(time.Millisecond), err)
	}
	return nil
}

func runCommandWithTimeout(dir string, env []string, timeout time.Duration, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("native Alicorn smoke timed out after %s", timeout)
		}
		return fmt.Errorf("native Alicorn smoke failed: %w", err)
	}
	return nil
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	filtered := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, prefix) {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, prefix+value)
}

func setRuntimePath(env []string, directory string) []string {
	key := "LD_LIBRARY_PATH"
	if runtime.GOOS == "darwin" {
		key = "DYLD_LIBRARY_PATH"
	} else if runtime.GOOS == "windows" {
		key = "PATH"
	}
	value := directory
	if existing := envValue(env, key); existing != "" {
		value += string(os.PathListSeparator) + existing
	}
	return setEnv(env, key, value)
}
