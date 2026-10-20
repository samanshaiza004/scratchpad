# Editor font selection

Scratchpad owns the installed-font catalog, picker and preference. Alicorn owns
the copied font bytes, shaping resources, retained text measurements and GPU
glyph resources. The feature replaces the `.Monospace` role; it does not add
per-family font handles or a second text engine. The `.UI` face stays unchanged.

## Native discovery

Windows uses DirectWrite's system font collection, selecting an upright face
nearest regular weight with normal stretch, plus an authentic italic/oblique
face when available. Family names prefer `en-US` for a stable preference and
fall back to the collection's first localized name. The catalog uses
`IDWriteFont1::IsMonospacedFont`, local font-file loader paths and the font
face's exact collection index. No directory-name or family-name heuristics
decide the selected face.

macOS uses CoreText's available descriptors, family names, file URLs, weight
and symbolic traits. Discovery retains selected collection faces' PostScript
names without reading collection bytes. On selection, the bounded reader
matches that name to one SFNT name table; ambiguous or missing matches fail.

Runa consumes a single SFNT. The reader extracts the chosen TTC/OTC face and
rebases its table offsets before validating it with Runa. Source files and
extracted faces have a 64 MiB limit. Unsupported, missing and unreadable fonts
produce a visible error and leave the current working font installed.

Only selected font bytes are read. The catalog is loaded on first picker open,
or at startup when restoring a custom family, and is reused during the session.
No font discovery or file reading occurs on idle frames or search keystrokes.
Catalog changes after launch require reopening Scratchpad.

Primary sources:

- [DirectWrite font enumeration](https://learn.microsoft.com/en-us/windows/win32/directwrite/font-enumeration)
- [Font face files](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-getfiles)
- [Collection face index](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwritefontface-getindex)
- [Local font file loader](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nn-dwrite-idwritelocalfontfileloader)
- [DirectWrite monospacing](https://learn.microsoft.com/en-us/windows/win32/api/dwrite_1/nf-dwrite_1-idwritefont1-ismonospacedfont)
- [CoreText available-font collection](https://developer.apple.com/documentation/coretext/ctfontcollectioncreatefromavailablefonts(_:))
- [CoreText font attributes](https://developer.apple.com/documentation/coretext/font-attributes)
- [CoreText PostScript names](https://developer.apple.com/documentation/coretext/ctfontcopypostscriptname(_:))

## Replacement and persistence

Picker actions queue one pending choice. The next primary build installs it
before `begin_frame`, after the preceding native presentation is complete.
The reader validates the regular and optional italic bytes first. Every open
editor Runtime receives the same bytes, and later floating windows install
the retained selection during initialization. Existing application-owned
wrapped-row indexes, horizontal extents and table plans are invalidated.
Active primary and detached views preserve source-relative viewport anchors;
other tabs retain an approximate scaled scroll position. Caret and selection
remain source byte positions.

The additive version-1 preference contains `theme`, `editor_font_family` and
`editor_font_size`. An empty family chooses bundled Atkinson Hyperlegible Mono.
The size defaults to 16 logical pixels and uses the existing editor zoom range
of 11.2–32 pixels. Theme changes save the font values too. Preference writes use
the existing staged same-directory atomic replacement. Failed persistence
keeps the current session settings and reports an error.

An absent optional italic face leaves emphasis upright. Fallback glyph behavior
remains the existing Alicorn primary/fallback role policy. The picker does not
promise arbitrary fallback chains, color emoji rendering, ligature settings,
or variable-axis controls.

## Validation

Regression fixtures cover font-byte ownership, invalid-load preservation,
exact two-face collection extraction, repeated replacement allocations, source
selection, actual wrapped-text reflow, focus and caret geometry, both current
and newly initialized floating runtimes, preference migration, theme/font
coexistence, large catalogs, narrow picker bounds and Settings text scaling.

The Windows discovery probe found 101 installed families, including 14
monospaced families. Consolas regular/italic loaded successfully, as did all 22
discovered faces with nonzero TTC indexes. These counts describe this machine,
not a required catalog size.

The Darwin adapter and its tests pass isolated `odin check -target:darwin_arm64`.
Native macOS enumeration and framework linking need verification on macOS.
Full Darwin frontend checking on this dependency branch currently stops in
Alicorn's existing secondary-window declarations, before it can validate the
whole application.

The final documented Windows integration suite passed: Go application and
Caliber boundary checks, Odin checking, 13 bridge tests and 142 frontend tests.
The rebuilt executable passed the Direct3D12 native smoke with
`SCRATCHPAD_DISABLE_SESSION=1` and `SCRATCHPAD_DISABLE_RECOVERY=1`, including
publication, wake delivery and ordered shutdown. The ordinary smoke's session
save was denied by the filesystem sandbox outside the workspace; the probe
confirmed `session_save_failed` under AppData. It was not a font-load failure.
Cross-platform native results must not be inferred from Windows validation.
