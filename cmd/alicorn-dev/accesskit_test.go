package main

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestAlicornAccessKitDetectionSupportsCurrentAndLegacyAdapterPaths(t *testing.T) {
	for _, relative := range []string{
		filepath.Join("host", "sdl3", "accessibility", "accesskit.odin"),
		filepath.Join("native", "sdl_gpu", "accessibility_accesskit.odin"),
	} {
		t.Run(relative, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, relative)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte("package fixture\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			found, err := alicornUsesAccessKit(root)
			if err != nil || !found {
				t.Fatalf("AccessKit detection = %t, error %v; want true, nil", found, err)
			}
		})
	}
}

func TestAlicornAccessKitDetectionAllowsNoIntegration(t *testing.T) {
	found, err := alicornUsesAccessKit(t.TempDir())
	if err != nil || found {
		t.Fatalf("AccessKit detection = %t, error %v; want false, nil", found, err)
	}
}

func TestAccessKitBootstrapPrefersPowerShell7(t *testing.T) {
	var requested []string
	path, err := accessKitPowerShell(func(name string) (string, error) {
		requested = append(requested, name)
		return "available/" + name, nil
	})
	if err != nil || path != "available/pwsh.exe" || !reflect.DeepEqual(requested, []string{"pwsh.exe"}) {
		t.Fatalf("bootstrap selected %q, requests %v, error %v; must not start legacy Windows PowerShell beneath pwsh CI", path, requested, err)
	}
}

func TestAccessKitBootstrapRetainsLegacyFallbackAndMissingShellError(t *testing.T) {
	unavailable := errors.New("shell unavailable")
	var requested []string
	path, err := accessKitPowerShell(func(name string) (string, error) {
		requested = append(requested, name)
		if name == "pwsh.exe" {
			return "", unavailable
		}
		return "legacy/powershell.exe", nil
	})
	if err != nil || path != "legacy/powershell.exe" || !reflect.DeepEqual(requested, []string{"pwsh.exe", "powershell.exe"}) {
		t.Fatalf("legacy fallback: path %q, requests %v, error %v", path, requested, err)
	}
	if _, err := accessKitPowerShell(func(string) (string, error) { return "", unavailable }); !errors.Is(err, unavailable) {
		t.Fatalf("missing shell error lost: %v", err)
	}
}
