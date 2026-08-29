package main

import (
	"flag"
	"fmt"
	"go.hasen.dev/shirei/app"

	"scratchpad/application"
	"scratchpad/ui"
)

func main() {
	flag.Parse()
	state := application.New(nil)
	if flag.NArg() > 1 {
		fmt.Println("usage: scratchpad [file-or-folder]")
		return
	}
	if flag.NArg() == 1 {
		if err := state.OpenPath(flag.Arg(0)); err != nil {
			fmt.Println(err)
		}
	}
	app.SetupWindow("Scratchpad", 960, 640)
	app.Run(func() { ui.RootView(state) })
}
