# Scratchpad live editor theme dogfood for Alicorn #166

Scratchpad has an opt-in development watcher for the editor theme. It compiles
stable JSON saves away from the UI thread, keeps the last valid candidate, and
adopts it on the application thread. The same compiled theme is applied to the
primary editor runtime and, when open, the detached editor runtime. No document,
selection, focus, or scroll state is changed by the reload path.

From a PowerShell prompt in the Scratchpad repository, copy the paper theme to
an ignored working file and launch with the Alicorn candidate checkout used for
the validation build:

```powershell
Copy-Item .\themes\scratchpad-paper.json .\out\scratchpad-live-editor-theme.json -Force
$env:SCRATCHPAD_LIVE_EDITOR_THEME_PATH = (Resolve-Path .\out\scratchpad-live-editor-theme.json).Path
$env:ALICORN_CANDIDATE_ROOT = 'C:\Users\saman\dev\alicorn\out\clones\issue-166-latest'
go run ./cmd/alicorn-dev run --odin C:\odin\odin.exe
```

Edit a color value under `scratchpad.palette.*` in the copied JSON and save it.
The active paper editor should repaint without restarting. For secondary-window
coverage, detach a second text document, then save another color change and
confirm both editor windows adopt it while retaining their own document,
selection, caret, focus, and scroll state. To exercise typing and scrolling,
make repeated color-only saves while editing and navigating a long document.

The terminal reports `[scratchpad-live-theme] candidate ready` and one
`applied window=primary` line, plus `applied window=secondary` when a floating
editor is open. A malformed or partially written save is rejected while the
last-good theme stays active; save valid JSON to recover. Color-only changes are
the useful repaint check. Editing theme metrics may correctly cause layout work.

When finished, stop Scratchpad and clear the opt-in variables:

```powershell
Remove-Item Env:SCRATCHPAD_LIVE_EDITOR_THEME_PATH -ErrorAction SilentlyContinue
Remove-Item Env:ALICORN_CANDIDATE_ROOT -ErrorAction SilentlyContinue
```
