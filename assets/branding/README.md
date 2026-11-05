# Scratchpad desktop icon and logo

Original raster artwork for Scratchpad.

## Primary assets
- `scratchpad-icon-1024.png` — transparent 1024px master.
- `Scratchpad.ico` — multi-resolution Windows icon (16, 20, 24, 32, 40, 48, 64, 72, 96, 128, 256).
- `Scratchpad.icns` — multi-resolution macOS icon including Retina representations.
- `Scratchpad.iconset/` — macOS iconset source assets; regenerate on Mac with `iconutil -c icns Scratchpad.iconset`.
- `scratchpad-wordmark-dark.png` — light text for use over dark backgrounds.
- `scratchpad-wordmark-light.png` — dark text for use over light backgrounds.

## Integration
**macOS:** Place `Scratchpad.icns` in the app bundle's `Contents/Resources/` and set `CFBundleIconFile` to `Scratchpad.icns` in `Contents/Info.plist`. Regenerate the .app bundle and check its Dock/Finder presentation.

**Windows:** Embed `Scratchpad.ico` as the application's ICON resource when linking the executable (for example using a `.rc` file and Windows resource compiler), rather than merely placing the `.ico` alongside the `.exe`. Rebuild and check File Explorer and taskbar presentation.

`Scratchpad.iconset/` can be rebuilt by Apple's iconutil if the prebuilt ICNS isn't accepted by your app-packaging process.

The source artwork is raster, not SVG; use the PNG master for further resizing.
