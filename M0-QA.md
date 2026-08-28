# M0 Manual QA Protocol

M0 validates platform behavior only. It does not authorize M1 unless every required row passes with current evidence.

## Build and install

1. Build the `Galpi` Release scheme with development signing.
2. Copy `Galpi.app` to `/Applications` and launch it once. Confirm that no Dock icon appears and a `G` status item appears.
3. In System Settings → Keyboard → Keyboard Shortcuts → Services, assign a shortcut to **Collect Word Context** (`Control-Option-Command-G` in the recorded run).
4. Open the evidence file from the Galpi status menu. Clear it before starting a clean run.
5. Record the macOS build, Galpi build identifier, display arrangement, content type, and service shortcut below.

The test must not grant Accessibility, Input Monitoring, or Screen Recording. Stop immediately if macOS requests one of those permissions.

## Required host matrix

Run both the Services menu and assigned shortcut on nonempty selectable text. Use representative selectable content and the negative case listed for each host.

| Host | Positive content | Negative/control content | Menu | Shortcut |
|---|---|---|---|---|
| Preview | Selectable-text PDF | Scanned/image-only PDF | Pass | Pass |
| Safari | Normal page body text | Empty/whitespace selection | Pass | Pass |
| Notes | Plain and rich text | Empty/whitespace selection | Pass | Pass |

Apple Books is explicitly deferred from the MVP because its reader does not vend visible EPUB selections through macOS Services. Its compatibility finding is retained under `M0-Evidence/deferred-books/` and is not part of this gate.

For every positive invocation:

1. Select text and invoke the service without switching applications.
2. Confirm that no visible app switch or application-switch animation occurs while the Galpi panel is visible.
3. Confirm the original selection remains visible before clicking back into the source.
4. Use Left, Right, Shift-Left, Shift-Right, Return, and Escape in separate runs. Confirm the panel receives each key while the original selection remains visible.
5. Repeat with clicks inside the panel, in the tested host, in another app, on the menu bar/status item, and on another display. Outside clicks must reach their target and dismiss the panel.
6. Repeat an invocation while a panel is already visible. Confirm the old monitor set is removed and only one panel remains.
7. Confirm the panel appears near the pointer, flips above it when lower space is insufficient, and stays inside each display's visible frame, including negative-coordinate displays.
8. Inspect JSONL evidence. It must contain pasteboard type names and panel state, but no selected text, window title, URL, or clipboard content.

## Evidence template

Copy one block per invocation into the test record. Do not include selected text.

```text
Run ID:
Local date/time:
macOS version/build:
Galpi build/configuration/signing identity:
Test host:
Content class:
Invocation: Services menu | assigned shortcut
Cold provider launch: yes | no
Pasteboard type names:
Panel ordered/key/main state:
First responder type:
Visible app switch or switch animation: none | details
Original selection visible before host click: pass | fail
Keyboard action exercised/result:
Outside-click target/result:
Monitor create/remove evidence event IDs:
Pointer/display/visible-frame/panel frame:
Unexpected privacy prompt: none | details
Result: pass | fail
Evidence JSONL line/event IDs:
Notes (no captured text):
```

## M0 pass gate

M0 passes only when all of the following are directly observed in a signed Release build:

- Preview, Safari, and Notes deliver nonempty selected text through the declared Service and assigned shortcut for the recorded positive content classes.
- No visible app switch or application-switch animation occurs.
- The panel becomes key, remains never-main, and receives the required keyboard actions while the original selection remains visible.
- The original selection remains visible until the tested host receives a click; Galpi does not synthesize or swallow that click.
- Outside dismissal works without Accessibility, Input Monitoring, Screen Recording, an event tap, or a global keyboard monitor.
- Local/global mouse monitor tokens are removed on dismissal, replacement, and termination; no post-removal callback is observed.
- Cursor placement and clamping pass on every attached display.
- Evidence contains no selected text and macOS shows no prohibited permission prompt.

Any failure is a hard stop. Record the exact host/content/version and evidence event IDs; do not add clipboard simulation, Accessibility fallback, or proceed to M1.
