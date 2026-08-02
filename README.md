# Scratchpad

Scratchpad is Youth’s fourth Utility Suite application and the Gate B proof
for one real host-owned text document. It targets `youth:app@0.0.8` and pins
the immutable SDK revision recorded in `Youth.lock`.

The file remains canonical. Scratchpad never places document content in Youth
state and never receives the full buffer while editing or saving. The host
opens one explicit relative grant, owns the Editor session, and performs an
exact-byte conflict check followed by atomic replacement only after the Save
turn commits.

## Run it

Create an existing `.txt` or `.md` file, then pass its containing directory and
relative name explicitly:

```bash
cargo build --manifest-path ../youth/Cargo.toml -p youth-cli
../youth/target/debug/youth dev \
  --workspace-root "$PWD/notes" \
  --document note.md
```

For one validated run without the development watcher:

```bash
../youth/target/debug/youth build
../youth/target/debug/youth run dist/dev.saman.scratchpad.wasm \
  --app-id dev.saman.scratchpad \
  --ephemeral \
  --workspace-root "$PWD/notes" \
  --document note.md
```

`--workspace-root` and `--document` are required together. The document must
already exist, remain inside the root, contain valid UTF-8, and be no larger
than 1 MiB after an optional UTF-8 BOM. Scratchpad itself accepts only `.txt`
and `.md`; the generic Youth capability does not impose extensions.

## Behavior

- The title row shows the normalized relative filename.
- Editing is host-local and does not call the guest for every keystroke.
- The first clean-to-dirty transition updates the status to `Unsaved changes`.
- The Save button and Primary+S request the same semantic effect.
- `Saving...` is installed by the committed request turn.
- Success accepts exactly the captured edit sequence and reports `Saved`.
- Newer typing remains dirty even if an older captured sequence was saved.
- An external byte change reports `Conflict`, keeps the local buffer, and
  leaves external bytes untouched.
- Restart reloads the canonical file and resets ephemeral status to `Saved`.

UTF-8 BOM presence, CRLF/LF, embedded NUL, and final-newline presence are
preserved. Gate B preserves ordinary permissions where supported but does not
promise universal ACL, xattr, ownership, resource-fork, or power-loss
durability guarantees.

## Verification

```bash
../youth/target/debug/youth check
../youth/target/debug/youth test
../youth/target/debug/youth build --release
```

The tests use isolated byte fixtures and the real headless runtime. They cover
editing, dirty transitions, button and Primary+S saves, exact file bytes,
BOM/CRLF preservation, conflict retention, restart, and view convergence. Host-only fault,
symlink, permission, shutdown, and conflict matrices live in the Youth
workspace because ordinary application tests cannot receive privileged
filesystem fault controls.

The application source contains no generated bindings, raw patches, numeric
identities, acknowledgements, absolute paths, hashes, file handles, or
full-text save plumbing. See `FINDINGS.md` for the evidence and limitations.

CI builds one canonical component on Ubuntu, records its manifest and SHA-256,
then mounts those exact bytes with an explicit temporary document grant on
Ubuntu, Windows, and macOS. Each host also builds and semantically tests the
locked source independently. Host-local hashes are logged as source-portability
evidence; byte-reproducible independent builds are not claimed.
