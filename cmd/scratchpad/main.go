package main

import (
	"go.hasen.dev/shirei/app"

	"scratchpad/ui"
)

func main() {
	app.SetupWindow("Scratchpad", 960, 640)
	app.Run(ui.RootView)
}
