# Scratchpad color themes

Scratchpad supports built-in palettes and local Alicorn JSON color themes.
Open **Settings → Appearance** to select a palette, import a theme, reload the
local catalog, or duplicate the current theme and customize a color. Theme
selection previews immediately; **Done** saves the selection and **Cancel**
restores the committed appearance. A candidate is compiled away from the UI
thread and adopted only after it is valid for the main and detached editor
runtimes. The last working appearance remains active if loading or adoption
fails.

## Local themes

Use **Import…** to copy a JSON theme into Scratchpad's per-user `themes`
directory. Scratchpad also discovers regular `.json` files there when it
starts. It does not watch the directory; choose **Reload themes** after editing
or adding files outside the application.

The directory is under the platform configuration root:

- Windows: `%LOCALAPPDATA%\Scratchpad\themes`
- macOS: `~/Library/Application Support/Scratchpad/themes`
- Linux: `$XDG_CONFIG_HOME/Scratchpad/themes`, or `~/.config/Scratchpad/themes`

Each file is limited to 1 MiB, and the catalog accepts at most 64 themes. Only
regular files are discovered; links and directories are ignored. Import
validates the file before installing it. Scratchpad writes the imported file
through a temporary file and atomically publishes it without replacing an
existing theme. A stable preference ID is derived from the installed filename;
renaming or removing a selected file makes that preference unavailable, so
Scratchpad falls back to Warm on the next launch.

## Theme format and layering

Theme files use Alicorn's versioned JSON color contract. A complete theme may
extend `alicorn.base`; Scratchpad always compiles the selected source over its
own Workbench and Paper defaults, so sparse files need only override colors
they want to change. For example:

```json
{
  "schema": 1,
  "contract": "0.2",
  "extends": "alicorn.base",
  "tokens": {
    "my-theme.accent": {
      "$type": "color",
      "$value": {
        "colorSpace": "srgb",
        "components": [0.48, 0.35, 0.78],
        "alpha": 1
      }
    }
  },
  "roles": {
    "core": {
      "accent": "{my-theme.accent}"
    }
  }
}
```

Scratchpad currently accepts color tokens and color role bindings. It rejects
other inheritance sources, non-color tokens and role bindings, material
definitions, and component recipe overrides. Layout, interaction, accessibility
signals, and **Standard / Flat / Workbench Relief** surface treatment remain
owned by Scratchpad and Alicorn, not by a color-theme file. Existing app roles
inherit Scratchpad's complete built-in defaults when omitted.

**Duplicate & customize…** preserves the selected source's color tokens and
role bindings and adds a color token and role binding for one of four commonly
used colors: Editor paper, Accent, Syntax keyword, or Workbench surface. A
bundled component recipe is left to Scratchpad's built-in defaults. The result
is an ordinary local Alicorn JSON color theme that can be edited or shared as
a file.

The bundled **Catppuccin Mocha** palette is available alongside Warm, Cool
Light, and Charcoal & Ink. Theme selection is stored in the versioned
`preferences.json`; invalid or missing saved themes fall back to Warm without
discarding other preferences.

For the full Alicorn theme contract, including token names, aliases, compiler
diagnostics, and command-line inspection, see [Alicorn typed themes](https://github.com/samanshaiza004/alicorn/blob/master/docs/themes.md)
and the [Scratchpad theme authoring notes](../frontends/alicorn/README.md#theme-authoring).
