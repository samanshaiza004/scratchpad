# Semantic zoom validation — 2026-10-24

This is an interaction experiment on `codex/anchored-semantic-zoom`, with the
companion Alicorn `codex/semantic-zoom-scroll` change. It is not a claim of
physical Windows/macOS acceptance. The implementation contract and usage are
in [Semantic zoom](../SEMANTIC_VIEWS.md); prior art is in
[the research note](../research/semantic-zoom.md).

## Automated checks

The Go application/Caliber suites cover deterministic Markdown, prose and Go
folds, stale revisions and parser results, source/selection preservation, CRLF,
long opening sentences, document instances, and large source workloads.

Odin source-row tests exercise disjoint/adjacent folds, expansion, and a million
logical lines with sparse metadata. Frontend tests exercise the actual staged
backend and source editor. Native scroll-capture tests exercise the shared
primary/secondary SDL event pump, exact retained-region targeting, modal and
inspector blocking, precise deltas, and claimed/unclaimed routing.

Validation host: Apple M1 / macOS 27.0, Odin
`dev-2026-09-nightly:a2fb372`, SDL 3.4.18. Scratchpad pins the published Alicorn
scroll-capture commit `f796cd480cd8d95f748989d01e9c0d9eb9a793ee` through its normal
dependency wrapper; no candidate override is needed.

| Check | Result |
| --- | --- |
| `go test -tags treesitter_release ./...` | Passed |
| Bridge module tests with `treesitter_release` | Passed in the integration runner |
| `sh tools/alicorn.sh test --odin <compiler>` | Passed: frontend type check, 13 bridge tests, 188 frontend tests, memory tracking enabled |
| Windows AMD64 frontend `odin check` | Passed; Windows execution not performed |
| Alicorn `tools/check.sh` | Passed: examples, foundation, 245 runtime and 35 theme tests, theme tooling |
| Alicorn `tools/test.sh` | Passed: foundation, runtime/theme, 108 native tests, 5 new scroll-capture tests, text-input contract and restoration subprocesses |
| Native development launch | Cocoa / SDL 3.4.18 / Metal initialization observed; isolated test app opened on temporary files |
| Optimized native `tools/alicorn.sh smoke --release` | Passed: publication rendered, wake observed, ordered shutdown; Cocoa / Metal, Retina scale 2 |

The regressions include byte/selection and shaped viewport round trips in Go
and wrapped Markdown, source pages separated by more than a normal window,
local expansion, exact table-cell hits, same-pump stale input, equal-revision
document replacement, idle optimistic-window replacement, and releasing distant
expansion anchors so subsequent scrolling can proceed. A poison allocator forces
eviction across more than 64 source pages before reconciliation and verifies
that emitted text and source hit testing remain valid.

Save/Undo/Redo and detached-window document/Runtime isolation use the real staged
backend. Gesture preference persistence includes existing preference-file
compatibility. Twelve attempted frames after settling perform zero additional
descriptions, shaping calls, or backend requests.

Desktop automation timed out while trying to interact with the isolated app;
the fixture was closed without touching other running Scratchpad processes.
The optimized smoke also confirms a rendered publication, event-driven wake, and
ordered shutdown. Neither check establishes physical wheel/IME/foreground
acceptance. The local executable uses this Mac's Homebrew SDL installation;
it is a development artifact, not a standalone redistributable bundle.

## Large-source measurements

Command: `go test -tags treesitter_release ./application -run '^$' -bench
'BenchmarkSemanticZoom(Prose|Structural)Transition' -benchtime=1x -benchmem`.
These single-iteration CPU measurements describe this machine and synthetic
fixtures, not portable latency guarantees or GPU performance. Structural fixture
projections are already current; parsing and input transport are outside timing.

| Million-line transition | Returned folds | Allocated bytes | Allocations | Observed time |
| --- | ---: | ---: | ---: | ---: |
| Prose Skim, 1,000 paragraphs | 1,000 | 10,390,808 | 4,056 | 23.14 ms |
| Markdown Overview, 1,000 sections | 1,000 | 9,401,792 | 3,049 | 21.49 ms |
| Go Overview, 1,000 symbols | 1,001 | 9,415,392 | 2,063 | 7.89 ms |
| Pathological prose opening sentence spanning almost all source | 1 | 9,045,192 | 13 | 206.44 ms |

Streaming through the existing piece tree with `Buffer.ReadAt` reduced the prose
Skim fixture from 66,460,200 to 10,390,808 allocated bytes per transition; the
long-sentence fixture fell from 93,046,288 to 9,045,192. The storage regression
checks partial reads, EOF, fragmented pieces, UTF-8 byte fidelity, and zero
allocation when the caller reuses storage.

The 100,000- and 1,000,000-line fixtures expose initial linear work; only visible
rendering is virtualized. Dense fixtures with 50,000 structures return an explicit
unsupported plan with zero folds rather than a truncated 4,096-fold result.
The 206 ms sentence scan remains a measured follow-up for large-input scheduling
or a documented semantic-query budget before broad release. No extra scheduler
or hidden polling was added for this experiment.

## Physical desktop matrix

These checks require a real input device and desktop. They remain unverified
unless explicitly recorded as performed.

| Scenario | Expected result | Status |
| --- | --- | --- |
| View menu / command palette / shortcuts | More/Less detail and Full source are discoverable; font zoom still works independently | Pending physical test |
| Cmd+Option+wheel on macOS; Ctrl+Alt elsewhere | One deterministic step per accumulated delta; ordinary wheel scrolls | Pending physical test |
| Trackpad inertia / modifier changes | Starting an ordinary scroll then pressing modifiers does not turn its tail into semantic zoom | Pending physical test |
| Gesture settings | Alternate Primary+Shift and Disabled work and survive restart | Pending physical test |
| Pointer over source; keyboard at caret | The source under attention stays represented; zooming in returns to its original byte | Pending physical test |
| Pointer over a marker/empty space | Uses the existing semantic anchor; does not jump to file start | Pending physical test |
| Nonzero scroll; top/bottom of file | Source identity survives; geometric clamping only at document edges | Pending physical test |
| Wrapped prose; narrow window; font zoom | Source rows remeasure and selection stays at the same source bytes | Pending physical test |
| Click collapsed range | Expands that range in place, without a second document surface | Pending physical test |
| Type/paste with hidden caret | Returns to Full, exposes the exact source selection, then edits those bytes | Pending physical test |
| Japanese/Chinese/Korean IME | Composition starts at the revealed source caret; candidate placement and committed bytes remain correct | Pending physical test |
| Pending edit/composition/selection drag | Zoom is refused while the input is outstanding | Pending physical test |
| Save / Undo / Redo while zoomed | Same buffer/history/save semantics; source mutation returns to Full without later automatic refolding | Pending physical test |
| Rapid zoom / delayed parser / external reload | Stale coordinates are rejected; source remains available | Pending physical test |
| Detached window | Gesture and keyboard menu actions affect its document and Runtime; primary view remains independent | Pending physical test |
| Modal, inspector, nested scrollable control | Gesture cannot take input from the covering/deeper control | Pending physical test |
| Return to idle | No descriptions, parser jobs, layout, or presentation repeat without an event | Pending physical test |

## Scope limits

Folds cover whole logical source lines; trailing text on the opening sentence's
line remains visible. Editing and caret-key navigation return to Full in this
first experiment. There is no animation, pinch recognizer, automatic fisheye
layout, or arbitrary manual fold-collapse UI. Very long chunked source lines
return to the ordinary source lane, which already supports chunk navigation.

Plans are built once per explicit transition and may scan all source bytes and
structural entries. Visible rendering is bounded, but initial plan construction
is not O(visible). The 250 ms gesture gap is a portable SDL heuristic rather than
an OS gesture phase. Physical trackpad and accessibility-zoom checks are required
before treating the default binding as settled.
