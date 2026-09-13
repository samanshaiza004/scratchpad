// gpui-dev is the small, portable build harness for the GPUI dogfood gates.
// It keeps the ordinary Scratchpad Go module independent from cgo/Caliber.
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

const expectedCaliberCommit = "abbe4f7"

type artifactManifest struct {
	CaliberCommit string   `json:"caliber_commit"`
	ABIVersion    uint32   `json:"abi_version"`
	Profile       string   `json:"profile"`
	Artifacts     []string `json:"artifacts"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "gpui-dev:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: go run ./cmd/gpui-dev <build|test|run|smoke|measure>")
	}
	command := args[0]
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	caliberRoot := flags.String("caliber-root", os.Getenv("CALIBER_ROOT"), "Caliber checkout")
	allowRevision := flags.Bool("allow-caliber-revision", false, "explicitly allow a non-pinned Caliber checkout")
	cgocheck2 := flags.Bool("cgocheck2", command == "test", "enable GOEXPERIMENT=cgocheck2")
	releaseBuild := flags.Bool("release", false, "build optimized native artifacts")
	outDir := flags.String("out", "frontends/gpui/build", "native artifact directory")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	root, err := repoRoot()
	if err != nil {
		return err
	}
	env, caliberLibrary, err := prepareCaliber(root, *caliberRoot, *allowRevision, *cgocheck2, *releaseBuild)
	if err != nil {
		return err
	}
	outPath := *outDir
	if !filepath.IsAbs(outPath) {
		outPath = filepath.Join(root, outPath)
	}
	out, err := filepath.Abs(outPath)
	if err != nil {
		return err
	}

	switch command {
	case "build":
		_, err = build(root, out, env, caliberLibrary, *releaseBuild)
	case "test":
		err = test(root, env, caliberLibrary, *releaseBuild)
	case "run":
		var exe string
		exe, err = build(root, out, env, caliberLibrary, *releaseBuild)
		if err == nil {
			err = launch(exe, env, false, "")
		}
	case "smoke":
		var exe string
		exe, err = build(root, out, env, caliberLibrary, *releaseBuild)
		if err == nil {
			err = launch(exe, env, true, root)
		}
	case "measure":
		var exe string
		exe, err = build(root, out, env, caliberLibrary, *releaseBuild)
		if err == nil {
			err = measure(root, out, exe, env)
		}
	default:
		return fmt.Errorf("unknown command %q; expected build, test, run, smoke, or measure", command)
	}
	return err
}

func repoRoot() (string, error) {
	output, err := commandOutput(".", "git", "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(output)), nil
}

func prepareCaliber(root, caliberRoot string, allowRevision, cgocheck2, releaseBuild bool) ([]string, string, error) {
	if caliberRoot == "" {
		return nil, "", errors.New("CALIBER_ROOT is required or pass --caliber-root")
	}
	caliberRoot, err := filepath.Abs(caliberRoot)
	if err != nil {
		return nil, "", err
	}
	commitBytes, err := commandOutput(caliberRoot, "git", "rev-parse", "HEAD")
	if err != nil {
		return nil, "", fmt.Errorf("inspect Caliber revision: %w", err)
	}
	commit := strings.TrimSpace(string(commitBytes))
	if !allowRevision && !strings.HasPrefix(commit, expectedCaliberCommit) {
		return nil, "", fmt.Errorf("Caliber checkout is at %s; expected %s (use --allow-caliber-revision to override)", commit, expectedCaliberCommit)
	}
	cargoArgs := []string{"build", "-p", "caliber-ffi", "--lib"}
	if releaseBuild {
		cargoArgs = append(cargoArgs, "--release")
	}
	if err := runCommand(caliberRoot, nil, "cargo", cargoArgs...); err != nil {
		return nil, "", err
	}
	library := caliberLibraryFromRoot(caliberRoot, releaseBuild)
	if _, err := os.Stat(library); err != nil {
		return nil, "", fmt.Errorf("Caliber cdylib was not found: %s: %w", library, err)
	}
	env := os.Environ()
	env = setEnv(env, "CGO_ENABLED", "1")
	env = setEnv(env, "CGO_LDFLAGS", "-L"+filepath.Dir(library))
	env = setEnv(env, "CGO_LDFLAGS_ALLOW", `-L.*|-l.*|-Wl,-rpath,.*`)
	env = setRuntimePath(env, filepath.Dir(library))
	if cgocheck2 {
		env = setEnv(env, "GOEXPERIMENT", mergeGoExperiment(os.Getenv("GOEXPERIMENT"), "cgocheck2"))
	}
	_ = root
	return env, library, nil
}

func build(root, out string, env []string, caliberLibrary string, releaseBuild bool) (string, error) {
	if err := os.MkdirAll(out, 0o755); err != nil {
		return "", err
	}
	backend := filepath.Join(out, backendLibraryName())
	backendDir := filepath.Join(root, "frontends", "gpui", "backend")
	goArgs := []string{"build", "-buildmode=c-shared", "-o", backend}
	if releaseBuild {
		goArgs = append(goArgs, "-ldflags", "-s -w")
	}
	goArgs = append(goArgs, "./cshared")
	if err := runCommand(backendDir, env, "go", goArgs...); err != nil {
		return "", err
	}
	caliberCopy := filepath.Join(out, filepath.Base(caliberLibrary))
	if err := copyFile(caliberLibrary, caliberCopy); err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		if err := relocateDarwinCaliber(caliberLibrary, caliberCopy, backend); err != nil {
			return "", err
		}
	}
	targetDir := filepath.Join(out, "cargo-target")
	manifest := filepath.Join(root, "frontends", "gpui", "Cargo.toml")
	cargoArgs := []string{"build", "--manifest-path", manifest, "--target-dir", targetDir}
	if releaseBuild {
		cargoArgs = append(cargoArgs, "--release")
	}
	if err := runCommand(root, env, "cargo", cargoArgs...); err != nil {
		return "", err
	}
	profile := "debug"
	if releaseBuild {
		profile = "release"
	}
	exe := filepath.Join(out, "scratchpad-gpui"+exeSuffix())
	if err := copyFile(filepath.Join(targetDir, profile, "scratchpad-gpui"+exeSuffix()), exe); err != nil {
		return "", err
	}
	manifestData := artifactManifest{
		CaliberCommit: expectedCaliberCommit,
		ABIVersion:    1,
		Profile:       profile,
		Artifacts:     []string{filepath.Base(exe), filepath.Base(backend), filepath.Base(caliberCopy)},
	}
	data, err := json.MarshalIndent(manifestData, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(out, "artifact-manifest.json"), append(data, '\n'), 0o644); err != nil {
		return "", err
	}
	return exe, nil
}

func relocateDarwinCaliber(source, copyPath, backend string) error {
	if err := runCommandWithEnv(".", nil, "install_name_tool", "-id", "@rpath/libcaliber_ffi.dylib", copyPath); err != nil {
		return err
	}
	installName := filepath.Join(filepath.Dir(source), "deps", filepath.Base(source))
	return runCommandWithEnv(".", nil, "install_name_tool", "-change", installName, "@rpath/libcaliber_ffi.dylib", backend)
}

func test(root string, env []string, caliberLibrary string, releaseBuild bool) error {
	if err := checkGofmt(root, "cmd/gpui-dev/main.go"); err != nil {
		return err
	}
	if err := runCommand(root, nil, "go", "test", "./..."); err != nil {
		return fmt.Errorf("root Scratchpad tests: %w", err)
	}
	backendDir := filepath.Join(root, "frontends", "gpui", "backend")
	if err := checkGofmt(backendDir, "protocol.go", "runtime.go", "caliber_cgo.go", "caliber_stub.go", "runtime_test.go", "cshared/backend.go"); err != nil {
		return err
	}
	if err := runCommand(backendDir, env, "go", "test", "./..."); err != nil {
		return fmt.Errorf("nested backend tests: %w", err)
	}
	out, err := filepath.Abs(filepath.Join(root, "frontends", "gpui", "build"))
	if err != nil {
		return err
	}
	exe, err := build(root, out, env, caliberLibrary, releaseBuild)
	if err != nil {
		return err
	}
	_ = exe
	manifest := filepath.Join(root, "frontends", "gpui", "Cargo.toml")
	if err := runCommand(root, nil, "cargo", "fmt", "--manifest-path", manifest, "--", "--check"); err != nil {
		return err
	}
	rustEnv := setEnv(env, "SCRATCHPAD_GPUI_BACKEND_LIBRARY", filepath.Join(out, backendLibraryName()))
	rustEnv = setRuntimePath(rustEnv, out)
	if err := runCommand(root, rustEnv, "cargo", "test", "--manifest-path", manifest); err != nil {
		return err
	}
	return runCommand(root, rustEnv, "cargo", "clippy", "--manifest-path", manifest, "--all-targets", "--", "-D", "warnings")
}

func checkGofmt(dir string, files ...string) error {
	cmd := exec.Command("gofmt", append([]string{"-l"}, files...)...)
	cmd.Dir = dir
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("gofmt check failed: %w", err)
	}
	if formatted := strings.TrimSpace(string(output)); formatted != "" {
		return fmt.Errorf("gofmt required for: %s", strings.ReplaceAll(formatted, "\n", ", "))
	}
	return nil
}

func launch(exe string, env []string, smoke bool, workspace string) error {
	launchEnv := append([]string{}, env...)
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_BACKEND_LIBRARY", filepath.Join(filepath.Dir(exe), backendLibraryName()))
	if smoke {
		launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_SMOKE", "1")
	}
	if workspace != "" {
		launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_WORKSPACE", workspace)
	}
	if runtime.GOOS == "linux" {
		if xvfb, err := exec.LookPath("xvfb-run"); err == nil {
			return runCommandWithEnv(".", launchEnv, xvfb, "-a", exe)
		}
	}
	return runCommandWithEnv(".", launchEnv, exe)
}

func launchForMeasure(exe string, env []string, workspace string, timeout time.Duration) error {
	launchEnv := append([]string{}, env...)
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_BACKEND_LIBRARY", filepath.Join(filepath.Dir(exe), backendLibraryName()))
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_SMOKE", "1")
	launchEnv = setEnv(launchEnv, "SCRATCHPAD_GPUI_WORKSPACE", workspace)
	name := exe
	args := []string(nil)
	if runtime.GOOS == "linux" {
		if xvfb, err := exec.LookPath("xvfb-run"); err == nil {
			name = xvfb
			args = []string{"-a", exe}
		}
	}
	return runCommandWithTimeout(".", launchEnv, name, timeout, args...)
}

func measure(root, out, exe string, env []string) error {
	manifestBytes, err := os.ReadFile(filepath.Join(out, "artifact-manifest.json"))
	if err != nil {
		return err
	}
	var manifest artifactManifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		return err
	}
	measurementPath := filepath.Join(out, "measurements.json")
	runtimeEnv := setEnv(env, "SCRATCHPAD_GPUI_BACKEND_LIBRARY", filepath.Join(out, backendLibraryName()))
	runtimeEnv = setRuntimePath(runtimeEnv, out)
	runtimeEnv = setEnv(runtimeEnv, "SCRATCHPAD_GPUI_MEASURE_PATH", measurementPath)
	manifestPath := filepath.Join(root, "frontends", "gpui", "Cargo.toml")
	if err := runCommand(root, runtimeEnv, "cargo", "test", "--manifest-path", manifestPath, "--test", "foreign_smoke", "--", "--nocapture"); err != nil {
		return err
	}
	measurements := map[string]any{}
	if data, readErr := os.ReadFile(measurementPath); readErr == nil {
		if unmarshalErr := json.Unmarshal(data, &measurements); unmarshalErr != nil {
			return fmt.Errorf("decode protocol measurements: %w", unmarshalErr)
		}
	}
	artifactBytes := map[string]int64{}
	for _, artifact := range manifest.Artifacts {
		if info, statErr := os.Stat(filepath.Join(out, artifact)); statErr == nil {
			artifactBytes[artifact] = info.Size()
		}
	}
	measurements["settling_interval_ms"] = 1000
	measurements["idle_rss_bytes"] = nil
	measurements["artifact_count"] = len(manifest.Artifacts)
	measurements["artifacts"] = manifest.Artifacts
	measurements["artifact_bytes"] = artifactBytes
	measurements["native_smoke"] = "pending"
	writeMeasurements := func() error {
		data, marshalErr := json.MarshalIndent(measurements, "", "  ")
		if marshalErr != nil {
			return marshalErr
		}
		return os.WriteFile(measurementPath, append(data, '\n'), 0o644)
	}
	if err := writeMeasurements(); err != nil {
		return err
	}
	start := time.Now()
	launchErr := launchForMeasure(exe, env, root, 30*time.Second)
	settled := time.Since(start)
	measurements["cold_start_to_shutdown_ms"] = settled.Milliseconds()
	if launchErr != nil {
		measurements["native_smoke"] = "unavailable"
		measurements["native_smoke_error"] = launchErr.Error()
	} else {
		measurements["native_smoke"] = "passed"
	}
	measurements["note"] = "Protocol timings come from the real Rust test path; RSS requires a native platform sampler."
	if err := writeMeasurements(); err != nil {
		return err
	}
	fmt.Printf("cold start to shutdown: %s\n", settled.Round(time.Millisecond))
	return launchErr
}

func runCommand(dir string, env []string, name string, args ...string) error {
	return runCommandWithEnv(dir, env, name, args...)
}

func runCommandWithEnv(dir string, env []string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = env
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	started := time.Now()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s failed after %s: %w", name, strings.Join(args, " "), time.Since(started).Round(time.Millisecond), err)
	}
	return nil
}

func runCommandWithTimeout(dir string, env []string, name string, timeout time.Duration, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = env
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	started := time.Now()
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("%s %s timed out after %s", name, strings.Join(args, " "), timeout)
		}
		return fmt.Errorf("%s %s failed after %s: %w", name, strings.Join(args, " "), time.Since(started).Round(time.Millisecond), err)
	}
	return nil
}

func commandOutput(dir, name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	data, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s %s failed: %w", name, strings.Join(args, " "), err)
	}
	return data, nil
}

func copyFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(destination, data, 0o755)
}

func backendLibraryName() string {
	switch runtime.GOOS {
	case "darwin":
		return "libscratchpad_gpui_backend.dylib"
	case "windows":
		return "scratchpad_gpui_backend.dll"
	default:
		return "libscratchpad_gpui_backend.so"
	}
}

func caliberLibraryFromRoot(root string, releaseBuild bool) string {
	name := "libcaliber_ffi.so"
	if runtime.GOOS == "darwin" {
		name = "libcaliber_ffi.dylib"
	} else if runtime.GOOS == "windows" {
		name = "caliber_ffi.dll"
	}
	profile := "debug"
	if releaseBuild {
		profile = "release"
	}
	return filepath.Join(root, "target", profile, name)
}

func exeSuffix() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}

func setEnv(env []string, key, value string) []string {
	prefix := key + "="
	for i, item := range env {
		if strings.HasPrefix(item, prefix) {
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

func setRuntimePath(env []string, dir string) []string {
	key := "LD_LIBRARY_PATH"
	if runtime.GOOS == "darwin" {
		key = "DYLD_LIBRARY_PATH"
	} else if runtime.GOOS == "windows" {
		key = "PATH"
	}
	current := ""
	for _, item := range env {
		if strings.HasPrefix(item, key+"=") {
			current = strings.TrimPrefix(item, key+"=")
			break
		}
	}
	if current != "" {
		dir += string(os.PathListSeparator) + current
	}
	return setEnv(env, key, dir)
}

func mergeGoExperiment(current, addition string) string {
	if current == "" {
		return addition
	}
	for _, part := range strings.Split(current, ",") {
		if part == addition {
			return current
		}
	}
	return current + "," + addition
}
