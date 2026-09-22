# Changes

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