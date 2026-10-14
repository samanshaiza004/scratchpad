package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type windowsStaticLinkRecipe struct {
	SchemaVersion int    `json:"schemaVersion"`
	Target        string `json:"target"`
	Linkage       string `json:"linkage"`
	Environment   struct {
		ODINRoot string `json:"ODIN_ROOT"`
	} `json:"environment"`
	Odin struct {
		Executable        string   `json:"executable"`
		CompilerArguments []string `json:"compilerArguments"`
	} `json:"odin"`
	Artifacts struct {
		SDL struct {
			Version string `json:"version"`
			Library string `json:"library"`
			SHA256  string `json:"sha256"`
			License string `json:"license"`
		} `json:"sdl"`
		AccessKit struct {
			Library  string   `json:"library"`
			SHA256   string   `json:"sha256"`
			Licenses []string `json:"licenses"`
		} `json:"accesskit"`
	} `json:"artifacts"`
	Provenance struct {
		Fingerprint string `json:"fingerprint"`
		Manifest    string `json:"manifest"`
	} `json:"provenance"`
}

func prepareWindowsStaticLinkRecipe(alicornRoot, odinExe string) (windowsStaticLinkRecipe, error) {
	if runtime.GOOS != "windows" || runtime.GOARCH != "amd64" {
		return windowsStaticLinkRecipe{}, errors.New("Alicorn's static native-link recipe supports Windows x64 only")
	}
	if _, err := os.Stat(filepath.Join(alicornRoot, "tools", "native_link_recipe.ps1")); err != nil {
		return windowsStaticLinkRecipe{}, fmt.Errorf("Alicorn native-link recipe script is unavailable: %w", err)
	}
	powershell, err := findPowerShell()
	if err != nil {
		return windowsStaticLinkRecipe{}, err
	}
	cmd := exec.Command(powershell,
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", filepath.Join(alicornRoot, "tools", "native_link_recipe.ps1"),
		"-Odin", odinExe, "-Target", "windows-x86_64",
	)
	cmd.Dir = alicornRoot
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return windowsStaticLinkRecipe{}, fmt.Errorf("Alicorn static recipe command failed: %w", err)
	}
	data := bytes.TrimSpace(stdout.Bytes())
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	var recipe windowsStaticLinkRecipe
	if err := json.Unmarshal(data, &recipe); err != nil {
		return windowsStaticLinkRecipe{}, fmt.Errorf("decode Alicorn static recipe JSON: %w", err)
	}
	if err := validateWindowsStaticLinkRecipe(recipe, odinExe); err != nil {
		return windowsStaticLinkRecipe{}, err
	}
	return recipe, nil
}

func findPowerShell() (string, error) {
	for _, name := range []string{"pwsh.exe", "pwsh", "powershell.exe", "powershell"} {
		if path, err := exec.LookPath(name); err == nil {
			return path, nil
		}
	}
	return "", errors.New("PowerShell is required to request Alicorn's native-link recipe")
}

func validateWindowsStaticLinkRecipe(recipe windowsStaticLinkRecipe, requestedOdin string) error {
	if recipe.SchemaVersion != 1 || recipe.Target != "windows-x86_64-msvc" || recipe.Linkage != "static" {
		return fmt.Errorf("unsupported Alicorn native-link recipe contract: schema=%d target=%q linkage=%q", recipe.SchemaVersion, recipe.Target, recipe.Linkage)
	}
	if recipe.Environment.ODINRoot == "" || !filepath.IsAbs(recipe.Environment.ODINRoot) {
		return errors.New("Alicorn native-link recipe has no absolute ODIN_ROOT")
	}
	if info, err := os.Stat(recipe.Environment.ODINRoot); err != nil || !info.IsDir() {
		return fmt.Errorf("Alicorn recipe ODIN_ROOT is unavailable: %s", recipe.Environment.ODINRoot)
	}
	if recipe.Odin.Executable == "" || recipe.Odin.Executable != requestedOdin {
		return fmt.Errorf("Alicorn recipe Odin executable %q does not match requested compiler %q", recipe.Odin.Executable, requestedOdin)
	}
	if len(recipe.Odin.CompilerArguments) != 1 || !strings.HasPrefix(recipe.Odin.CompilerArguments[0], "-extra-linker-flags:") {
		return errors.New("Alicorn native-link recipe must provide one Odin -extra-linker-flags argument")
	}
	if recipe.Artifacts.SDL.Version == "" || recipe.Provenance.Fingerprint == "" || recipe.Provenance.Manifest == "" {
		return errors.New("Alicorn native-link recipe is missing SDL version or generation provenance")
	}
	if err := validateRecipeFile(recipe.Artifacts.SDL.Library, recipe.Artifacts.SDL.SHA256); err != nil {
		return fmt.Errorf("validate prepared SDL library: %w", err)
	}
	if err := validateRecipeFile(recipe.Artifacts.AccessKit.Library, recipe.Artifacts.AccessKit.SHA256); err != nil {
		return fmt.Errorf("validate prepared AccessKit library: %w", err)
	}
	if filepath.Clean(recipe.Artifacts.SDL.Library) != filepath.Clean(filepath.Join(recipe.Environment.ODINRoot, "vendor", "sdl3", "SDL3.lib")) {
		return errors.New("Alicorn recipe SDL library is outside its declared Odin overlay")
	}
	if len(recipe.Artifacts.AccessKit.Licenses) != 2 {
		return errors.New("Alicorn native-link recipe must provide both AccessKit license files")
	}
	for _, license := range append([]string{recipe.Artifacts.SDL.License}, recipe.Artifacts.AccessKit.Licenses...) {
		if !filepath.IsAbs(license) {
			return fmt.Errorf("Alicorn recipe license path must be absolute: %q", license)
		}
		info, err := os.Stat(license)
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return fmt.Errorf("Alicorn recipe license is missing or empty: %s", license)
		}
	}
	if !filepath.IsAbs(recipe.Provenance.Manifest) {
		return errors.New("Alicorn native-link recipe manifest path must be absolute")
	}
	if info, err := os.Stat(recipe.Provenance.Manifest); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("Alicorn recipe provenance manifest is unavailable: %s", recipe.Provenance.Manifest)
	}
	return nil
}

func validateRecipeFile(path, expectedSHA256 string) error {
	if !filepath.IsAbs(path) || len(expectedSHA256) != 64 {
		return fmt.Errorf("invalid artifact path or SHA-256 for %q", path)
	}
	actualSHA256, err := fileSHA256(path)
	if err != nil {
		return err
	}
	if !strings.EqualFold(actualSHA256, expectedSHA256) {
		return fmt.Errorf("SHA-256 mismatch for %s: got %s, want %s", path, actualSHA256, expectedSHA256)
	}
	return nil
}
