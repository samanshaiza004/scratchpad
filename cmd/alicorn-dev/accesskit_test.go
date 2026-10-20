package main

import (
	"errors"
	"reflect"
	"testing"
)

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
