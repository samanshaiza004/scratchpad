//go:build darwin

package workspace

import (
	"fmt"
	"os/exec"
	"strings"
)

type darwinTrasher struct{}

func (darwinTrasher) Trash(path string) error {
	quoted := strings.ReplaceAll(path, `\`, `\\`)
	quoted = strings.ReplaceAll(quoted, `"`, `\"`)
	script := fmt.Sprintf(`tell application "Finder" to delete POSIX file "%s"`, quoted)
	if output, err := exec.Command("osascript", "-e", script).CombinedOutput(); err != nil {
		return fmt.Errorf("move to Finder Trash: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}
