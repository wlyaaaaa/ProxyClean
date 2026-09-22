# Changes

## 2026-09-22: two daily intents, separate maintenance

- Replaced the homepage toolbox with one stable repair action and one secondary client-disconnect action. Technical controls live in a separate maintenance window; detailed logs are chronological and collapsed in a separate details window.
- Group recognized controllers, cores and helpers by client. Discover actual ports, preserve other clients, ask for a client only when several are running, and retain client selection across same-user elevation.
- Preview normal client/service exit before effects. Force-close requires a separate confirmation and fresh identity check; restart or port takeover blocks cleanup. Related multi-port references use one reversible settings operation, not successive undo records.
- Automatically verify configuration and basic webpage connectivity after confirmed repair/close. Preserved PAC, tunnels, other clients and application-specific proxy settings remain explicit limitations, never hidden behind a generic direct-connect success.
- Preserved UTF-16 VBS launchers byte-for-byte across Git checkout; Git text newline conversion had corrupted fresh-checkout launchers despite a working local copy.
- Kept one daily root launcher; moved historical batch/VBS shortcuts into `旧版入口/` with corrected relative paths. The launcher now validates all three XAML views and the client workflow module.
- All 181 regression tests pass in PowerShell 7.6.4 and Windows PowerShell 5.1; actual WPF smoke tests, six read-only GUI navigation paths, and real isolated cooperative/uncooperative client shutdown paths were verified. The user's live proxy and settings were not modified by acceptance tests.


## 2026-09-22: launch and handoff closeout

- Both root entries check the complete package and show Chinese errors for missing files, startup failures and abnormal child exits. Module initialization is inside the visible error boundary.
- Preserve the actual selected operation, adapter, port, expected client and original Windows user through elevation; show matching guidance and require confirmation again instead of executing on startup.
- Request elevation before restoring route changes, retain ordinary current-user undo without unnecessary elevation, and distinguish explicit requested changes from stale-proxy diagnosis.
- Added 24 handler and launcher regressions. All 137 tests passed on PowerShell 7.6.4 and Windows PowerShell 5.1; both actual WPF read-only smoke runs passed. Root launch/recheck, incomplete package, module failure, parser failure, account mismatch and selected-action preview were also exercised without changing live network settings.

## 2026-09-22: guided Chinese interface and shared workflow

- Added the root `00-打开 ProxyClean.vbs` entry and a native white/green WPF interface. Legacy shortcuts now open a preview-first GUI instead of immediately mutating the network.
- Automatic local read-only inspection, a single contextual primary action, readable Chinese results, real background progress, cooperative inspection cancellation, and collapsed advanced operations.
- Shared CLI/GUI execution workflow with explicit confirmation, same-user elevation checks, safe error messages, independent connectivity results, and opt-in DNS flushing.
- Revalidate proxy addresses and listener state before applying a plan and again at the effect boundary; preserve prior undo when preflight discovers a changed condition.
- Preserve exact legacy client selection, redacted diagnostics, durable recovery, and clear warnings for full-process termination and adapter operations.
- Added decision, race-condition, WhatIf, privacy, workflow and launcher regression coverage; read-only GUI smoke mode also verifies the responsive dispatcher.

## 2026-09-18 — scoped recovery and visible controls

- Shared endpoint/address-family classification; preserve mixed mappings, unknown evidence and dynamic listener discovery.
- Atomic pre-effect DPAPI journal, verified reverse recovery, bounded undo and preservation of externally changed resources.
- Exact process identity for requested ports; no implicit whole-client termination by old port.
- Disconnected adapter selection, checked reset and IPv6 recovery; no-write redacted diagnosis by default.
- Visible control center, preview-before-apply, anonymous exit comparison and Docker configuration/runtime distinction.
- PowerShell 7-preferred launchers with Windows PowerShell 5.1 compatibility; behavior tests reject missing/incomplete discovery.