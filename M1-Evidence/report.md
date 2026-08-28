# M1 Local Capture Evidence Report

## Scope

M1 turns the M0 diagnostic callback into a local, production-shaped selection panel for Safari, Preview, and Notes. Apple Books remains deferred. M1 adds no persistence, Keychain, database, network, OpenAI, or library behavior.

Selected text exists only in memory and is rendered only in the transient capture panel so the user can choose a word or phrase. Retained JSONL, receipts, and automation artifacts contain no sentence or selected surface text, clipboard data, title, URL, application identity, or process identity. Content-bearing screenshots are intentionally not retained.

## Implemented behavior

- NFC normalization, line-ending/Unicode-whitespace collapse, trim, empty rejection, and a 2,000-Unicode-scalar sentence limit.
- NaturalLanguage word token ranges for English, Japanese, and mixed script, with punctuation/separator gaps preserved when reconstructing a contiguous selected surface.
- One anchor/focus selection model shared by keyboard and mouse.
- Left/Right movement, Shift-Left/Shift-Right range extension and shrink, token click, contiguous token drag, Return, and Escape.
- Return confirms only a nonempty surface of at most 500 Unicode scalars. Confirmation is an in-memory M1 state and creates no write or request.
- A 501-scalar selection is visibly ineligible and remains ineligible after Return.
- Key-capable, never-main `.nonactivatingPanel` behavior; pointer placement/clamping; replacement, outside-click pass-through, and termination cleanup.
- Content-free callback/panel signposts and JSONL metadata.
- Menu-bar shortcut/privacy guidance stating that M1 text is not saved or sent.

## Automated verification

`M1-Evidence/receipts/test.txt` records a passing 24-test suite. It covers:

- normalization and empty input;
- 2,000/2,001 and 500/501 scalar boundaries;
- English, Japanese, and mixed-script segmentation;
- apostrophes, punctuation, separators, and surface reconstruction;
- UTF-16 hit mapping around non-token emoji;
- keyboard anchor/focus and immediate over-limit state;
- mouse contiguous ranges;
- panel placement, clamping, negative-coordinate displays, and screen fallback;
- key/non-main/nonactivating panel state;
- generation-safe replacement and monitor balance;
- explicit evidence-field whitelist and encoded privacy schema.

The default Apple Development-signed Release build passed. `/Applications/Galpi.app` was replaced with that exact Release product and passes strict codesign and plist validation.

## Native host matrix

`host-matrix.json` binds each route to its JSONL SHA-256, panel state, action list, and monitor balance.

| Host | Services menu | Assigned shortcut | Mouse click | Full shortcut keys | Result |
|---|---:|---:|---:|---:|---:|
| Safari | Pass | Pass | Pass | Pass | **Pass** |
| Preview | Pass | Pass | Pass | Pass | **Pass** |
| Notes | Pass | Pass | Pass | Pass | **Pass** |

For every route, `panelReady` is key and non-main and monitor creation/removal is balanced. Shortcut evidence contains Left, Right, Shift-Left, Shift-Right, Return, and Escape. Menu evidence contains keyboard movement, Return, mouseSelect, and Escape. `mouse-drag-live.jsonl` separately records a paced live drag expanding one token to a contiguous five-token range. During live observation, each source selection remained visibly selected behind the Galpi panel.

## Boundaries and lifecycle

- `surface-501.jsonl`: the selected surface is 501 scalars and `confirmationEligible=false` both before and after Return.
- `sentence-2001.jsonl`: exactly one content-free `serviceRejected` event with reason `sentenceTooLong`; no panel or monitor is created.
- Whitespace-only selected input creates no panel and no evidence file.
- `lifecycle.jsonl`: two creates and two monitor sets, one replacement dismissal/removal, and one global outside-click dismissal/removal.
- `termination.jsonl`: a live panel is dismissed with reason `termination`, its monitor set is removed once, and the evidence queue is flushed before exit.
- `mouse-drag-live.jsonl`: live mouse selection expands monotonically from one through five contiguous tokens.

## Privacy and prohibited-capability audit

Retained JSONL was parsed against the content-free evidence schema. Source scans found no Accessibility API, Input Monitoring, Screen Recording, event tap, global keyboard monitor, general-pasteboard/copy simulation, source/frontmost-app observation, URLSession/networking, database, GRDB, Keychain, OpenAI, or M2+ implementation.

The temporary UI screenshots used during live observation were not copied into the repository. `app-automation-transcript.json` is the retained content-free native structural proof.

## Performance disposition

Callback and panel-visible clocks/signposts are retained for diagnostics. M1 does **not** claim the original external-camera 150 ms p95 gate because the specified physical camera/shared-clock evidence was not produced. That performance measurement remains an explicit M4/release verification item and is not replaced by internal timestamps.

## Artifacts

- `app-automation-transcript.json`
- `host-matrix.json`
- `safari-menu.jsonl`, `safari-shortcut.jsonl`
- `preview-menu.jsonl`, `preview-shortcut.jsonl`
- `notes-menu.jsonl`, `notes-shortcut.jsonl`
- `surface-501.jsonl`, `sentence-2001.jsonl`
- `lifecycle.jsonl`, `termination.jsonl`
- `mouse-drag-live.jsonl`
- `receipts/test.txt`, `receipts/release-build.txt`
- `receipts/codesign-verify.txt`, `receipts/codesign-details.txt`, `receipts/plist-lint.txt`

## Gate disposition

**M1 local capture vertical slice: PASS.**

The next permitted milestone is M2a. M2b remains forbidden until the M2a model gate passes and the user explicitly approves the measured selected-model cost.
