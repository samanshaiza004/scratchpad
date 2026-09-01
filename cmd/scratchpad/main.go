package main

import (
	"flag"
	"fmt"
	"go.hasen.dev/shirei"
	"go.hasen.dev/shirei/app"
	"os"
	"path/filepath"

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
	state.SetWake(shirei.RequestNextFrame)
	stateDir, _ := application.DefaultStateDir()
	sessionPath := filepath.Join(stateDir, "session.json")
	recoveryDir := filepath.Join(stateDir, "recovery")
	state.RecoveryDir = recoveryDir
	if flag.NArg() > 1 {
		fmt.Println("usage: scratchpad [file-or-folder]")
		return
	}
	if flag.NArg() == 1 {
		if err := state.OpenPath(flag.Arg(0)); err != nil {
			fmt.Println(err)
		}
	} else {
		if _, err := os.Stat(filepath.Join(recoveryDir, "manifest.json")); err == nil {
			_ = state.RestoreRecovery(recoveryDir)
		} else {
			_ = state.RestoreSession(sessionPath)
		}
	}
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
