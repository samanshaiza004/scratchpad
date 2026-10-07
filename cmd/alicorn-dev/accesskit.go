package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const accessKitVersion = "0.23.1"

func accessKitLinkerFlags(alicornRoot string) (string, error) {
	// Older Alicorn checkouts do not use AccessKit and should not need its
	// native distribution just to build Scratchpad.
	if _, err := os.Stat(filepath.Join(alicornRoot, "native", "sdl_gpu", "accessibility_accesskit.odin")); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", fmt.Errorf("inspect Alicorn AccessKit integration: %w", err)
	}

	flags, library, err := accessKitLinkerFlagsFor(alicornRoot, runtime.GOOS, runtime.GOARCH)
	if err != nil || flags == "" {
		return flags, err
	}
	if _, err := os.Stat(library); err == nil {
		return flags, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("inspect AccessKit library %s: %w", library, err)
	}

	if err := bootstrapAccessKit(alicornRoot); err != nil {
		return "", err
	}
	if _, err := os.Stat(library); err != nil {
		return "", fmt.Errorf("Alicorn AccessKit bootstrap completed without the expected library %s: %w", library, err)
	}
	return flags, nil
}

// accessKitLinkerFlagsFor mirrors Alicorn's pinned native link contract. Paths
// are absolute because Odin is invoked from Scratchpad, while the ignored
// dependency cache belongs to the selected Alicorn checkout.
func accessKitLinkerFlagsFor(alicornRoot, goos, goarch string) (string, string, error) {
	var libraryDirectory string
	switch goos {
	case "windows":
		if goarch != "amd64" {
			return "", "", fmt.Errorf("Alicorn AccessKit Windows library is configured for amd64, not %s", goarch)
		}
		libraryDirectory = filepath.Join(alicornRoot, ".deps", "accesskit", "accesskit-c-"+accessKitVersion, "lib", "windows", "x86_64", "msvc", "static")
		flags := fmt.Sprintf("/LIBPATH:%s bcrypt.lib ntdll.lib propsys.lib runtimeobject.lib uiautomationcore.lib userenv.lib ws2_32.lib", quoteLinkerPath(libraryDirectory))
		return flags, filepath.Join(libraryDirectory, "accesskit.lib"), nil
	case "darwin":
		arch := goarch
		if arch == "amd64" {
			arch = "x86_64"
		}
		if arch != "arm64" && arch != "x86_64" {
			return "", "", fmt.Errorf("Alicorn AccessKit macOS library does not support architecture %s", goarch)
		}
		libraryDirectory = filepath.Join(alicornRoot, ".deps", "accesskit", "accesskit-c-"+accessKitVersion, "lib", "macos", arch, "static")
		flags := fmt.Sprintf("-L%s -framework AppKit -framework Foundation -framework CoreFoundation -lobjc -lc++", quoteLinkerPath(libraryDirectory))
		return flags, filepath.Join(libraryDirectory, "libaccesskit.a"), nil
	case "linux":
		// The native AccessKit bridge is currently disabled on Linux.
		return "", "", nil
	default:
		return "", "", fmt.Errorf("Alicorn AccessKit linking is not configured for %s/%s", goos, goarch)
	}
}

func quoteLinkerPath(path string) string {
	if strings.ContainsAny(path, " \t\"") {
		return `"` + strings.ReplaceAll(path, `"`, `\"`) + `"`
	}
	return path
}

func appendLinkerFlags(args []string, flags string) []string {
	if flags == "" {
		return args
	}
	return append(args, "-extra-linker-flags:"+flags)
}

func bootstrapAccessKit(alicornRoot string) error {
	switch runtime.GOOS {
	case "windows":
		return bootstrapAccessKitWindows(alicornRoot)
	case "darwin":
		return bootstrapAccessKitDarwin(alicornRoot)
	default:
		return nil
	}
}

func bootstrapAccessKitWindows(alicornRoot string) error {
	helper := filepath.Join(alicornRoot, "tools", "common.ps1")
	if _, err := os.Stat(helper); err != nil {
		return fmt.Errorf("AccessKit library is missing and Alicorn bootstrap helper is unavailable at %s: %w", helper, err)
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		powershell, err = exec.LookPath("pwsh.exe")
	}
	if err != nil {
		return fmt.Errorf("AccessKit library is missing; Powershell is required to run Alicorn's pinned bootstrap helper: %w", err)
	}
	quotedHelper := strings.ReplaceAll(helper, "'", "''")
	script := fmt.Sprintf(". '%s'; Get-AlicornAccessKit | Out-Null", quotedHelper)
	cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script)
	cmd.Dir = alicornRoot
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run Alicorn's AccessKit bootstrap helper: %w", err)
	}
	return nil
}

func bootstrapAccessKitDarwin(alicornRoot string) error {
	helper := filepath.Join(alicornRoot, "tools", "accesskit.sh")
	if _, err := os.Stat(helper); err != nil {
		return fmt.Errorf("AccessKit library is missing and Alicorn bootstrap helper is unavailable at %s: %w", helper, err)
	}
	cmd := exec.Command("sh", "-c", ". ./tools/accesskit.sh && alicorn_accesskit_linker_flags >/dev/null")
	cmd.Dir = alicornRoot
	cmd.Env = append(os.Environ(), "REPO_ROOT="+alicornRoot)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run Alicorn's AccessKit bootstrap helper: %w", err)
	}
	return nil
}
