# GPUI source and license ledger

This ledger records the GPUI dependencies and reusable upstream material for
the Scratchpad frontend migration. It is an audit of Scratchpad commit
`e621f3b14ca97b989925e675ffce6ff9e4b51b17` and the exact dependency resolution
in [`frontends/gpui/Cargo.lock`](../frontends/gpui/Cargo.lock).

The frontend is MIT-licensed Scratchpad code. A dependency is not a source
reuse event: Cargo links the published package and its license remains the
package's license. A source reuse event occurs only when Scratchpad copies or
adapts upstream source into this repository. No third-party source was copied
into the GPUI frontend at this audit point.

## Rules for this migration

* Keep `gpui-kit` as the facade and prefer its maintained components over
  copying their implementation into Scratchpad.
* If a component must be adapted, inspect the source file's license header and
  the package metadata at the pinned commit first. Record the file path, exact
  commit, license, change notice, and attribution in this document in the
  same change that introduces the adaptation.
* Zed has mixed licensing. The GPUI crates and other files explicitly marked
  Apache-2.0 are eligible for copying under Apache-2.0. Zed application/editor
  code is generally GPL-3.0-or-later and is architecture/test/UX reference
  material only. Do not copy, translate line by line, or lightly rewrite GPL
  Zed editor/application code into Scratchpad's MIT tree.
* If a Zed file's header or package metadata is absent or ambiguous, treat it
  as unavailable for copying until the license is resolved.
* Cargo's transitive packages below are runtime/build dependencies, not a
  grant to use their source independently. In particular, do not use the
  target-specific capture, font, or XIM crates as a source-reuse shortcut.

## Current dependency audit

`frontends/gpui/Cargo.toml` directly depends on `gpui-kit = "=0.6.1"`.
The facade enables its default `component` and `assets` features and pins one
matching family of GPUI crates. The Scratchpad source currently imports the
facade's GPUI APIs plus these component APIs:

* `gpui_kit::base::Selectable`;
* `gpui_kit::component::button::Button`;
* `gpui_kit::component::list::ListItem`;
* `gpui_kit::component::tab::{Tab, TabBar}`; and
* `gpui_kit::component::tree::{Tree, TreeItem, TreeState}`.

The lockfile also resolves the platform-specific GPUI crates and their
transitive dependencies. Only the packages relevant to source reuse and
license review are listed individually here; ordinary utility crates remain
Cargo-managed dependencies and are not copied by Scratchpad.

| source repository | source path | source commit / package pin | license | use | changes made | attribution / notice requirement |
| --- | --- | --- | --- | --- | --- | --- |
| [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit) | `crates/kit` (`gpui-kit`) | `36b51819deb52c947a79f8de29e0e9175eda7464`, package `0.6.1`, Cargo checksum `a74f10f4499d99378c73c0251541a5d92bde45cb83dd658f0618fb32769d5898` | Apache-2.0 | Current direct dependency and facade; re-exports matching GPUI, base, component, and assets layers. | None; linked as a registry dependency. | Preserve the Apache-2.0 license if source is redistributed. No Scratchpad notice is required for the current binary link beyond the dependency/license inventory maintained for releases. |
| [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit) | `crates/base` (`gpui-base`) | `96103905ea0c9c199db206ada7a9b2e3114e6339`, package `0.6.1`, Cargo checksum `9d45dcaaeac889bf1e7757db1beb26c9043c8ea3156651facc11c6be56bb6722` | Apache-2.0 | Transitive foundation used by the facade. Reusable candidates include `src/input/`, `src/input/base/`, `src/input/editor/`, `src/input/editor/display_map/`, focus, accessibility, virtual lists, scrollbars, and motion. | None. Existing Rust code calls the exported `Selectable` behavior; it does not embed base source. | A copied/adapted file must retain the Apache header and include the Apache license; mark modified files as required by Apache-2.0. |
| [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit) | `crates/component` (`gpui-component`) | `36b51819deb52c947a79f8de29e0e9175eda7464`, package `0.6.1`, Cargo checksum `52b7ab4921dc9d2624648fb40580067bfe0f47dd14f5f8e6f070d40c6d4246d4` | Apache-2.0 | Current shell components (`Button`, `ListItem`, `Tab`, `TabBar`, `Tree`) and future candidates for command palette, menus, dialogs, search, tabs, tree, virtual lists, input, settings, and accessibility. | None; used through `gpui-kit`. | Keep Apache-2.0 source notices if copied. Prefer dependency use so upstream notices remain package-managed. |
| [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit) | `crates/component-macros` (`gpui-component-macros`) | `96103905ea0c9c199db206ada7a9b2e3114e6339`, package `0.6.1`, Cargo checksum `21fee2d71a84a6af828e7915a1b4c6721610a47ba5ef30b35c2f8edafdd753cc` | Apache-2.0 | Transitive procedural macros for `gpui-component`. | None. No macro source is copied. | Apache-2.0 applies if source is ever copied; normal Cargo use needs no source notice in Scratchpad files. |
| [longbridge/gpui-kit](https://github.com/longbridge/gpui-kit) | `crates/assets` (`gpui-kit-assets`) | `dd667dfc2f925b7321dc4aef3dc7049b16ed01a2`, package `0.6.1`, Cargo checksum `be79bcf18842485308282d138cffaacb6191ece5643f4ee66d1828524be2a8e3` | Crate code Apache-2.0; bundled Lucide assets ISC, with Feather-derived icons under MIT | Enabled by the facade's default `assets` feature. Candidate icon source for shell controls. | None. No SVG or asset file has been copied into Scratchpad. | If bundled icons are registered in a distributable app, retain `LICENSE-LUCIDE` attribution (including ISC and Feather MIT text). If icons are copied, retain the corresponding notices in the app's third-party notices. |
| [zed-industries/zed](https://github.com/zed-industries/zed) | `crates/gpui`, `crates/gpui_platform`, `crates/gpui_macros`, `crates/gpui_wgpu`, `crates/gpui_windows`, `crates/gpui_linux`, `crates/gpui_macos`, `crates/gpui_web`, and the `gpui-pre-*` support crates | GPUI Kit's `gpui-pre = 0.3.4` metadata records `zed@6916400`; Cargo checksum `20199390dbd6cfbb7f0cb2ca57b46120cc1f434746a77367d2780657e0973725` | Apache-2.0 for the GPUI snapshot and the `gpui-pre-*` packages; package `LICENSE-APACHE` is present | Transitive GPUI runtime and platform implementation. Use as the GPUI rendering, input, focus, window, shaping, testing, and platform API foundation. The pinned package is the permitted reuse surface; it is not a license grant for Zed's application/editor tree. | None; Scratchpad links the published snapshot through `gpui-kit`. | For copied/adapted Apache GPUI files, retain copyright/license notices, include Apache-2.0, preserve NOTICE content if present, and mark modified files. Never copy Zed GPL application/editor files. |
| [zed-industries/font-kit](https://github.com/zed-industries/font-kit) / [servo/font-kit](https://github.com/servo/font-kit) | `src/` (`zed-font-kit`) | Zed fork commit `94b0f28166665e8fd2f53ff6d268a14955c82269`, package `0.14.1-zed`, Cargo checksum `a3898e450f36f852edda72e3f985c34426042c4951790b23b107f93394f9bff5` | MIT OR Apache-2.0 | macOS/platform transitive font backend of `gpui-pre`; not directly imported by Scratchpad. | None. | Do not copy it as a shortcut for Scratchpad font code. If independently reused later, retain the selected MIT or Apache notices from the package. |
| [zed-industries/xim-rs](https://github.com/zed-industries/xim-rs) | `zed-xim` package source | `16f35a2c881b815a2b6cdfd6687988e84f8447d8`, package `0.4.0-zed`, Cargo checksum `0c0b46ed118eba34d9ba53d94ddc0b665e0e06a2cf874cfa2dd5dec278148642` | MIT | Linux/X11 transitive IME backend of `gpui-pre`; not directly imported by Scratchpad. | None. | Do not copy it as a substitute for GPUI's `InputHandler`. If reused, retain the package's MIT notice. |
| [helmerapp/scap](https://github.com/helmerapp/scap) | `zed-scap` package source | `4afea48c3b002197176fb19cd0f9b180dd36eaac`, package `0.0.8-zed`, Cargo checksum `b6b338d705ae33a43ca00287c11129303a7a0aa57b101b72a1c08c863f698ac8` | Cargo metadata says MIT; the packaged `LICENSE` contains a nonstandard additional competitive-rank condition | Target-specific screen-capture transitive of `gpui-pre`; Scratchpad does not request screen capture. | None. Do not use or copy. | Treat the packaged license as requiring separate legal review before any direct use or redistribution. This package is not a source-reuse candidate. |

The full `gpui-pre` closure also includes `gpui-pre-collections`,
`gpui-pre-http-client`, `gpui-pre-macros`, `gpui-pre-refineable`,
`gpui-pre-scheduler`, `gpui-pre-shared-string`, `gpui-pre-sum-tree`,
`gpui-pre-util`, `gpui-pre-util-macros`, `gpui-pre-zlog`,
`gpui-pre-ztracing`, and `gpui-pre-ztracing-macro`. Their package manifests and
`LICENSE-APACHE` files identify the same Zed `6916400` Apache-2.0 snapshot.
They are all transitive dependencies; no source from them is present in
Scratchpad.

## Candidate reuse map

These are the first places to inspect when implementing parity. They are
candidate sources, not copied code. The migration should use the public
`gpui-kit` facade whenever it exposes the required behavior.

| Scratchpad need | Preferred source | status and boundary |
| --- | --- | --- |
| Native text input, IME preedit/commit, UTF-16 mapping, clipboard, caret geometry, selection drag | `gpui-base` `src/input/`, especially `input/base/{native,state,selection,movement}.rs` and `input/textarea/` | Reuse through APIs or adapt only Apache-licensed files after header review. Local document bytes, revisions, and edit validation remain Go-owned. |
| Bounded editor viewport, wrapping, folds, visual rows, hit testing | `gpui-base` `src/input/editor/display_map/{display_map,wrap_map,fold_map,text_wrapper}.rs`; GPUI `text_system` and `elements` | Architecture and API reference first. Do not adopt the component editor's document as Scratchpad authority; keep the Caliber bounded-window contract. |
| File tree and keyboard navigation | `gpui-component` `tree`, `list`, `virtual_list`; `gpui-base` focus and virtual-list primitives | Current tree already uses the component. Keep focus/selection and hover state in Rust; send only semantic file operations over Caliber. |
| Tabs, menus, command palette, dialogs, popovers | `gpui-component` `tab`, `menu`, `command`, `dialog`, `popover`, `searchable_list` | Prefer maintained components and style them with Aero Paper tokens. Map actions to `commands.InitialVocabulary`; do not invent a second semantic command set. |
| Search and large result lists | `gpui-component` `searchable_list`, `virtual_list`, `scroll`; `gpui-base` list/scroll behavior | Frontend owns focus, navigation, cancellation presentation, and scrolling; Go remains search authority. |
| Accessibility and test support | `gpui-base` accessibility/focus semantics; `gpui-kit` `test-support` feature and native snapshot helpers | Enable only when the parity test slice needs it. Test semantic state and interaction rather than Shirei pixels. |
| Low-level rendering, shaping, platform behavior, key dispatch | Zed `gpui` Apache snapshot under `gpui-pre` (`crates/gpui*`) | Dependency/API and architecture reference. Do not copy Zed app/editor code. |

The following Zed paths are explicitly out of bounds for source reuse unless a
future audit proves an individual file is Apache-2.0 and records it here:
`crates/editor`, `crates/workspace`, `crates/project`, `crates/language`, and
other product/application crates. Their behavior may inform independent
Scratchpad implementations and test cases, but Scratchpad's implementation
must be authored against its own Go/Caliber ownership model.

## Existing Scratchpad code review

The files under `frontends/gpui/src/`, `frontends/gpui/tests/`, and
`frontends/gpui/backend/` at the audit commit contain no copied third-party
license headers, Zed application code, or adapted upstream file blocks. The
current shell and bounded editor spike are Scratchpad-authored code that uses
the `gpui-kit` API. Their source remains covered by the repository's MIT
license.

The existing `Cargo.lock` is the reproducibility record for registry source:
when a future lockfile update changes a package, refresh this ledger's source
commit, checksum, license files, and reuse status in the same change. A
release process should generate a complete third-party license inventory from
the resolved lockfile before shipping a GPUI binary.

## Required entry for future copied code

Every future source-reuse change must add an entry with this shape before the
code lands:

```text
source repository: https://...
source path: crates/.../src/...
source commit: full 40-character revision
license: SPDX expression and the inspected header/license file
use: dependency | copied | adapted | architecture reference only
changes made: ...
attribution/notice requirement: ...
```

For Apache-2.0 code, retain the copyright and license notices, preserve any
upstream NOTICE text, and identify modified files. For MIT code, retain the
copyright and permission notice. If a source file is GPL or its status cannot
be established, record it as architecture reference only and implement the
behavior independently.
