# M4 Release Candidate QA

## Scope and hard stops

Supported capture hosts are Safari, Preview, and Notes. Apple Books remains deferred and must not be claimed. Use a signed Release build on macOS 14 or later with synthetic content only.

Stop if the app requests Accessibility, Input Monitoring, Screen Recording, or another privileged capture permission. Production capture must not use event taps, global keyboard monitoring, clipboard simulation, source scraping, source activation, or source/frontmost identity.

Do not record selected or confirmed text, Entry fields, provider output, credentials, account identifiers, personal paths, dynamically observed or inferred source/frontmost app identity, titles, URLs, clipboard metadata, or pasteboard identifiers in QA evidence. Predetermined case labels for the approved Safari, Preview, and Notes test matrix are allowed; they are test inputs, not runtime source attribution. Screenshots and transcripts must remain content-free.

## Release identity

Record content-free digests for the frozen source, signed executable, test result summary, automation transcript, screenshot, and each audit receipt. Verify:

- Release build succeeds.
- `codesign --verify --deep --strict` succeeds.
- `Info.plist` and entitlements lint successfully.
- Sandbox and network-client entitlements are present; prohibited permissions are absent.
- GRDB.swift 7.11.1 is the only package dependency.
- The exact production model remains `gpt-5.6-luna`.

## Signed host matrix

For each host, exercise Services menu and configured shortcut routes with selectable synthetic content and a whitespace/unsupported-content control:

| Host | Menu | Shortcut | Panel key/non-main | Selection controls | Confirm | Outside/Escape cleanup |
|---|---|---|---|---|---|---|
| Safari |  |  |  |  |  |  |
| Preview |  |  |  |  |  |  |
| Notes |  |  |  |  |  |  |

The panel must remain `.nonactivatingPanel`, become key without becoming main, clamp to the pointer display's visible frame, pass outside clicks through, replace an existing panel cleanly, and remove balanced monitor tokens on every dismissal and termination path.

## Accessibility and keyboard order

Inspect the status item, capture panel, API-key Settings, and Library with signed QA automation. Verify meaningful labels/help for every control and these cycles:

- Capture panel: selection group → visible Settings or Retry action → selection group.
- Library Entries: mode → search → list → editor fields → history → completed detail → actions → mode. The unresolved-status filter is hidden and inapplicable in Entries mode.
- Library Unresolved: mode → status filter → list → unresolved detail → retry actions → delete → Settings → refresh → mode. Search remains visible for layout stability but is disabled and skipped by keyboard traversal in Unresolved mode.
- API-key Settings: secure field → Save/Replace → Remove when present → Cancel.

No background database, connectivity, lookup, or recovery event may activate the app, reopen Library, or recreate a dismissed panel.

## Retention, retry, and deletion disclosures

Confirm the UI truthfully states:

- Before confirmation, selected text is memory-only.
- Return stores the normalized sentence and exact surface locally and sends both to OpenAI with `store:false`.
- Closing the panel does not cancel or delete confirmed durable work.
- The API key is stored only in Keychain; removing it stops new requests but does not delete Library data.
- Deleting an unresolved lookup removes that lookup.
- Deleting an Entry permanently removes the Entry and all linked Encounter history after count disclosure and confirmation.

Exercise confirmation cancellation, stale-count failure, accepted deletion, active-request cancellation after commit, and SQLite cascade cleanup.

## Persistence, network, and recovery matrices

Use synthetic databases and clients; do not mutate the production Keychain or use real network calls.

- New empty v1 database, reopen, `quick_check`, foreign-key audit, and zero-row cleanup.
- Known offline: no Keychain read, attempt claim, request, or timer spin.
- Missing key: manual-only failure, zero attempts, zero provider requests.
- Offline → online and wake/clock-change recovery.
- Relaunch abandoned-claim repair while excluding live active claims.
- Transient storage retry with bounded backoff.
- Permanent completion failure with no second provider request.
- Commit-before-cancel unresolved deletion and late-result rejection.
- Global lookup concurrency remains one.

## Multi-display matrix

Verify pointer/display selection and visible-frame clamping for:

- primary display,
- secondary display,
- negative display coordinates,
- pointer outside all frames selecting the nearest display,
- panel larger than or near an edge of the visible frame,
- display arrangement or visible-frame change between invocations.

Record geometry only; do not record source application or content.

## Asynchronous termination matrix

Run each case against the same signed Release identity and require bounded process exit, exactly one termination reply, evidence flush, panel removal, balanced monitor-token cleanup, and clean relaunch:

| Case | Required precondition | Required result |
|---|---|---|
| Idle | No panel or active lookup | Immediate clean exit and zero windows on relaunch |
| Open panel | Unconfirmed synthetic panel is key | Panel dismissed, both monitors removed, no retained draft |
| Running lookup | Synthetic gated client owns one request | Request cancelled as control flow, no false provider failure, one termination reply |
| Scheduled/known-offline retry | Pending durable work with a future due time or known-offline state | No timer spin or attempt consumption during shutdown; durable work remains recoverable |
| Storage failure | Synthetic storage fault during active transition | No hang or false success; durable state remains consistent |
| Database initialization failure | Safely isolated unavailable database path | No executor exists, termination returns immediately, and the next clean launch recreates or opens v1 |

The transcript must record only structural states, counts, sanitized categories, and run identity. Do not use real network or mutate the production Keychain for running/offline/storage cases; those branches use deterministic package tests plus signed idle/open-panel/database-failure termination.

## External-camera performance gate

This is the separate physical M4 goal. Use a 240 fps or faster external camera and programmable USB HID keyboard with an LED triggered in the same controller action as the Services shortcut. Record 30 warm samples for each supported host using one video clock from the first LED-transition frame to the first changed panel-pixel frame. Report raw frame indices/deltas and nearest-rank p95 (sorted sample 29). Each host must be at or below 150 ms. Keep cold launch trials and internal callback-to-panel signposts separate; never mix clocks.
