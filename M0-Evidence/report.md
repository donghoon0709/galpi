# M0 MVP Evidence Report — Pass

## MVP contract

M0 validates permissionless selected-text delivery for Safari, Preview, and Notes through the declared macOS Service, using both the Services menu and the assigned shortcut. The diagnostic panel must remain non-main, become key, receive keyboard input, preserve the visible selection, dismiss without swallowing the outside click, and clean up every monitor token.

Apple Books is deferred from the MVP. Its reader does not vend visible EPUB selections through macOS Services; the compatibility finding is retained under `deferred-books/` for later product work.

Runtime JSONL retains only Service timing, pasteboard type names, panel state, geometry, and keyboard/dismissal events. No screenshots are retained because screenshots of selected text or unrelated desktop content would violate the content-free evidence boundary.

## Build and signing verification

Current receipts are stored under `receipts/` and include the exact commands, exit codes, stdout, and stderr.

- `xcodebuild -project Galpi.xcodeproj -scheme Galpi -destination 'platform=macOS' test`: passed, including all six `PanelPositionerTests` cases.
- Default Release configuration is bound to the local Apple Development team and identity; a plain Release build without command-line signing overrides passed.
- Installed build: `/Applications/Galpi.app`, bundle build 2.
- `codesign --verify --deep --strict --verbose=2`: passed.
- `codesign -d --verbose=4`: retained signing metadata.
- `plutil -lint`: passed.
- Static audit found no Accessibility API, event tap, global keyboard monitor, activation call, general-pasteboard capture, Screen Recording, or Input Monitoring implementation.
- Whitespace-only Service input returned successfully but created no panel or evidence.

## Assigned shortcut

`Collect Word Context` was enabled under System Settings → Keyboard → Keyboard Shortcuts → Services → Text and assigned `Control-Option-Command-G`.

## Required-host and route results

Each route has a separate JSONL file. `host-matrix.json` binds the host, route, SHA-256 of the evidence file, panel state, action list, and monitor counts.

| Host | Services menu | Assigned shortcut | Key/non-main panel | Full shortcut keyboard set | Result |
|---|---:|---:|---:|---:|---:|
| Safari | Pass | Pass | Pass | Pass | **Pass** |
| Preview | Pass | Pass | Pass | Pass | **Pass** |
| Notes | Pass | Pass | Pass | Pass | **Pass** |

For every host:

- the Services-menu evidence records a successful callback, key/non-main `panelReady`, Escape action, dismissal, and monitor removal;
- the assigned-shortcut evidence records a successful callback and the complete required action set: Left, Right, Shift-Left, Shift-Right, Return, and Escape;
- every retained `panelReady` has `panelIsKeyWindow=true` and `panelIsMainWindow=false`.

## Panel and monitor lifecycle

`lifecycle-evidence.jsonl` records two Service invocations while the first panel was visible, followed by a native click outside the replacement panel.

Audited invariants:

- exactly two `panelCreate` events;
- exactly two `monitorCreate` events;
- exactly one replacement `panelDismiss` and matching `monitorRemove`;
- exactly one outside-dismiss `panelDismiss` and matching `monitorRemove`;
- no duplicate dismissal or monitor-removal event;
- both `panelReady` events are key and non-main;
- the native outside click reached Safari and no panel remained afterward.

The global mouse callback is bound to the panel instance it monitors, so an already-delivered callback from a replaced panel cannot dismiss the replacement.

`termination-evidence.jsonl` separately records a live panel followed by application termination. `applicationWillTerminate` produced exactly one termination `panelDismiss` and one matching `monitorRemove`, then synchronously flushed the evidence queue before exit.

## Geometry

The six focused unit tests cover placement below the pointer, flip-above behavior, horizontal and vertical clamping, negative-coordinate displays, containing-screen selection, and nearest-screen fallback. Runtime evidence now records both `pointerLocation` and the actual `panelFrame` together with the selected `screenFrame`. The runtime panel size is fixed at 360×120 points, below the visible dimensions of the attached test displays.

## Privacy evidence

Every supported-host and lifecycle JSONL line was parsed. The retained evidence contains state metadata only. Selected text, clipboard contents, window titles, URLs, application identity, process identity, and observed application state are absent. Content-bearing screenshots were deliberately removed.

## Artifacts

- `host-matrix.json` — route-to-file index and SHA-256 receipts.
- `app-automation-transcript.json` — content-free macOS Services/shortcut/outside-click/termination automation transcript.
- `safari-menu.jsonl`, `safari-shortcut.jsonl`.
- `preview-menu.jsonl`, `preview-shortcut.jsonl`.
- `notes-menu.jsonl`, `notes-shortcut.jsonl`.
- `lifecycle-evidence.jsonl` — replacement, outside dismissal, and cleanup.
- `termination-evidence.jsonl` — termination dismissal, monitor removal, and flush.
- `receipts/test.txt` — current test receipt.
- `receipts/release-build.txt` — current signed Release build receipt.
- `receipts/codesign-verify.txt`, `receipts/codesign-details.txt`, `receipts/plist-lint.txt`.
- `deferred-books/books-probe.json` — content-free historical compatibility result for the deferred host.

## Gate disposition

**Three-host M0 MVP: PASS.**

Safari, Preview, and Notes satisfy the current M0 contract without prohibited permissions or capture fallbacks. Apple Books is not part of the MVP gate and remains deferred. No M1+ feature was added during M0.
