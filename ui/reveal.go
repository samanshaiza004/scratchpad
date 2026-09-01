package ui

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// revealPath delegates the file-manager integration to the host OS. Keeping
// this behind the command dispatcher makes the workbench behavior testable
// without launching a native process.
func revealPath(path string) error {
	if path == "" {
		return errors.New("empty path")
	}
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.Command("open", "-R", path)
	case "windows":
		command = exec.Command("explorer", "/select,"+path)
	default:
		// xdg-open opens files in their associated application, so reveal the
		// containing directory instead.
		directory := filepath.Dir(path)
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			directory = path
		}
		command = exec.Command("xdg-open", directory)
	}
	return command.Start()
}
