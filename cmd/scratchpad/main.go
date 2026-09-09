package main

import (
	"errors"
	"flag"
	"fmt"
	"go.hasen.dev/shirei"
	"go.hasen.dev/shirei/app"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"scratchpad/application"
	"scratchpad/language/treesitter"
	"scratchpad/ui"
	"scratchpad/workspace"
)

func main() {
	version := flag.Bool("version", false, "print build and language-service capabilities")
	flag.Parse()
	if *version {
		caps := treesitter.Capabilities()
		fmt.Printf("Scratchpad dev\nTree-sitter: %s\nGo: %t\nTypeScript: %t\nTSX: %t\n", caps.Backend, caps.Go, caps.TypeScript, caps.TSX)
		return
	}
	state := application.New(nil)
	state.SetTrasher(workspace.NewOSTrasher())
	state.SetWake(shirei.RequestNextFrame)
	stateDir, _ := application.DefaultStateDir()
	sessionPath := filepath.Join(stateDir, "session.json")
	recoveryDir := filepath.Join(stateDir, "recovery")
	state.RecoveryDir = recoveryDir
	if flag.NArg() > 1 {
		fmt.Println("usage: scratchpad [file-or-folder]")
		return
	}
	var explicitPath string
	if flag.NArg() == 1 {
		explicitPath = flag.Arg(0)
	}
	restoreStartup(state, recoveryDir, sessionPath, explicitPath)
	watcher, _ := workspace.NewOSWatcher()
	if watcher != nil {
		_ = state.SetWatcher(watcher)
		defer watcher.Close()
	}
	app.SetupWindow("Scratchpad", 960, 640)
	app.Run(func() { ui.RootView(state) })
	_ = state.FlushRecovery(recoveryDir)
	_ = state.SaveSession(sessionPath)
}

func restoreStartup(state *application.Application, recoveryDir, sessionPath, explicitPath string) {
	manifestPath := filepath.Join(recoveryDir, "manifest.json")
	recoveryFound := false
	recoveryFailed := false
	if _, err := os.Stat(manifestPath); err == nil {
		recoveryFound = true
		if err := state.RestoreRecovery(recoveryDir); err != nil {
			fmt.Printf("could not restore recovery: %v\n", err)
			recoveryFailed = true
			if failedDir, quarantineErr := quarantineRecovery(recoveryDir); quarantineErr != nil {
				// If the failed snapshot cannot be moved out of the active
				// recovery directory, keep blocking writes so startup cannot
				// replace evidence that may still be recoverable.
				fmt.Printf("could not quarantine recovery: %v\n", quarantineErr)
				state.SetRecoveryWritesBlocked(true)
			} else {
				// The failed snapshot is now preserved under its own name. The
				// normal recovery directory is free to receive new snapshots.
				fmt.Printf("failed recovery preserved at %s\n", failedDir)
				state.SetRecoveryWritesBlocked(false)
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		fmt.Printf("could not inspect recovery: %v\n", err)
		recoveryFailed = true
		state.SetRecoveryWritesBlocked(true)
	}

	// Crash recovery takes precedence over normal session/CLI policy. An
	// explicit path is opened afterward, preserving recovered documents while
	// making the requested path active.
	if explicitPath != "" {
		if err := state.OpenPath(explicitPath); err != nil {
			fmt.Println(err)
		}
		return
	}
	if recoveryFound && !recoveryFailed {
		return
	}
	if err := state.RestoreSession(sessionPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		fmt.Printf("could not restore session: %v\n", err)
	}
}

func quarantineRecovery(recoveryDir string) (string, error) {
	parent := filepath.Dir(filepath.Clean(recoveryDir))
	base := filepath.Base(filepath.Clean(recoveryDir))
	stamp := strconv.FormatInt(time.Now().UnixNano(), 10)
	for attempt := 0; attempt < 100; attempt++ {
		suffix := stamp
		if attempt > 0 {
			suffix += "-" + strconv.Itoa(attempt)
		}
		failedDir := filepath.Join(parent, base+".failed."+suffix)
		if _, err := os.Lstat(failedDir); err == nil {
			continue
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		if err := os.Rename(recoveryDir, failedDir); err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return "", err
		}
		return failedDir, nil
	}
	return "", errors.New("could not choose a unique quarantine path")
}
