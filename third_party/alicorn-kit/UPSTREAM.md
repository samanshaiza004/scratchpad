# AliKit source snapshot

This source snapshot is vendored from `samanshaiza004/alicorn-kit` commit
`856447e2083a2261d8f5b01a8ca436142f597de5` under the MIT License. Scratchpad
vendors AliKit's command-palette and Tree View packages so its public source
remains buildable without credentials for the private AliKit repository.

The snapshot includes the UI-independent tree model, Alicorn tree presentation,
component guides, and canonical Tree View example. Update the snapshot from a
reviewed AliKit commit and update this revision.

Scratchpad carries a compatibility backport of the Tree View focus and
selection fixes upstreamed in AliKit commit
`cff5c029`. The backport synchronizes the tree's model from matching semantic
focus before key handling and row description, and applies pointer selection
after all rows in the current description have been built. The rest of AliKit
`main` is not vendored because its scoped-input integration requires the newer
Alicorn revision; update the dependency and snapshot together when adopting that
API.

Other vendored changes must be ported upstream before they are added here.
