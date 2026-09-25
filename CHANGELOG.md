# Changes

## 2026-09-25: one-click close, restartability and honest DNS diagnostics

- Treat one client-close click as normal exit plus bounded automatic cleanup of the same verified residual processes. Keep necessary Windows UAC, bind continuation to the same user and process instance, and remove repeated application confirmations.
- Restore previously running recognized launch brokers even when close or settings cleanup fails. Keep standalone proxy-core services stopped, preserve service startup settings, bound service-start waits and refuse success if recovery fails or a core restarts.
- Handle natural process exit races without retry prompts. Close controllers before cores and brokers; do not chase replacement processes or reused ports.
- Refresh only the DNS cache after verified client exit. Distinguish repeated DNS-resolution failures from mixed network errors, use bounded two-site HTTP probes, and show actionable DNS guidance without silently changing resolver configuration.
- All 277 repository tests pass in PowerShell 7.6.4 and Windows PowerShell 5.1; both WPF hosts construct without showing a window. Extend service, process, DNS and actual GUI-handler regressions, update the complete-package launcher, and document that live client shutdown/reopen was deliberately not exercised.

## 2026-09-24: fix disconnect preview with no active system-proxy endpoints

- Keep absent endpoint lists as empty collections, not null pipeline entries, across client previews, home inspection and public snapshot conversion. Optional discovery inputs tolerate null elements without treating them as dead endpoints or weakening required endpoint validation.
- Fix the pre-shutdown `DisconnectPreview` binding exception when the system proxy is disabled, its address is empty, or the setting could not be read. The same fault no longer hides running clients behind an `unknown` home-page observation.
- Add 22 regressions that retain the real client-discovery algorithm while isolating operating-system queries and effects. The original code fails 15 of them; the fix passes all 22. All 215 repository tests pass in PowerShell 7.6.4 and Windows PowerShell 5.1.
- Verify live read-only standard-user and same-user elevated previews, plus actual WPF smoke runs on both hosts. No live proxy client is stopped during acceptance; the existing shutdown confirmations and registry-write repair remain intact.

## 2026-09-24: fix client-close registry writes

- Replace writes through read-only `Get-Item` registry handles with writable registry-provider operations. Client cleanup can now update WinINET values and remove user proxy variables; undo retains original registry kinds and literal expandable strings.
- Preserve the existing field allowlist, idempotent deletion, pre-write checks and recovery flow. Dispose read handles after inspection.
- Add 12 regressions using disposable registry keys and journals, including both FlyingBird and Clash Verge normal/force workflows with all process shutdown and live network effects mocked. The old writer failed 10 of these tests; the corrected writer passes all 12. All 193 repository tests pass in PowerShell 7.6.4 and Windows PowerShell 5.1. No live proxy shutdown was performed.

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