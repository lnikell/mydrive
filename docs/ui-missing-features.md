# MyDrive UI — functionality checklist

## Implementation status — 19 October 2026

The SMB functionality below is now connected in source while retaining the new UI's layout and visual components:

- Provider-owned Online-only and Kept Offline libraries, counts, cache measurements, pin-preserving Clear Cache and automatic cache maintenance.
- Per-file transfer progress, speeds, pause/resume, persistent recent history, retry, conflict acknowledgement and durable daily totals. Folder imports report individual files and obey the configured worker count.
- SMB share enumeration, whole-mount Keep Downloaded, three connection steps, cancellation rollback, new-mount selection and per-mount Info settings.
- Login, Dock/menu bar/Finder preferences, network/wake reconnect, notifications, exclusions, bandwidth limits/schedules and transfer/retry settings.
- Credential-free profile import/export, SMB Mountain Duck bookmark import, Keychain Access, logs, Finder registration repair and SMB discovery entry points. Tailnet discovery requires an installed and signed-in Tailscale CLI; unavailable and error states are shown explicitly.

SFTP, WebDAV, S3 and the default SSH key remain disabled as coming-soon features. SMB Guest remains disabled because the transport requires signed, named-account sessions. Keep both copies remains the only supported conflict strategy.

Automated checks and isolated UI checks cover these implementations. End-to-end qualification of the current signed build is still in progress. Notarized distribution and the installed Sparkle update also remain separate release gates. The original gap inventory is retained below for reference.

## Original UI inventory

The host app UI was rebuilt from the Figma file **Flux-Academy-Workshop → Page 4 → "03 — Pro Table — Dark"** and its continuation frames (`03.1`–`03.7`):
https://www.figma.com/design/m8wmZtg76Rr1VNfsuIF885/Flux-Academy-Workshop?node-id=103-860

Rule used during the rebuild: **every control is in place, only behaviour that already existed is wired.** Anything without a backend is either hidden until data exists, shown disabled with the app's real current behaviour, or shows "—". Nothing displays invented numbers. This file lists each gap so it can be implemented separately.

Figma frames (node IDs, for `get_design_context`):

| Frame | Node | SwiftUI |
|---|---|---|
| 03 Main table | `103:863` (window) | `MainWindow.swift`, `Sidebar.swift`, `MountsPane.swift`, `StatusStrip.swift` |
| 03.1 Activity | `109:1259` | `ActivityPane.swift` |
| 03.2 Add button + menu | `108:1062`, `108:1359`, `108:1421` | `MenuButton.swift` (`AddMenuButton`, `AddMenu`) |
| 03.3 Empty, first launch | `109:9716` | `MountsPane.swift` (`FirstLaunchView`) |
| 03.4 Empty, no results | `109:10027` | `MountsPane.swift` (`NoResultsView`) |
| 03.5 Empty, everything synced | `109:10289` | `ActivityPane.swift` (`UpToDateView`) |
| 03.6 / 03.7 Settings | `108:9425`, `108:9542`, `108:9685`, `108:9819` | `SettingsView.swift` |
| 03.8 Add SMB mount, in context | `114:1042` (sheet `114:1245`) | `DriveConnectionSheet.swift` |
| 03.9 Add SMB mount, states | `118:1170` | `DriveConnectionSheet.swift` |
| Foundations: icons, Drive Icon, tokens | `98:401` | `DesignSystem.swift`, `MacApp/Resources/Icons/*.svg` |
| Foundations — Forms: Input, Button, Popup, Segmented | `113:1041` | `DesignSystem.swift` (`InputChrome`, `ReadOnlyValue`, `PopupChrome`, `FormGroup`, `FormRow`, `FormError`, `SegmentedPicker`) |

## What is wired to real behaviour

- Mount list from `AppModel.drives`; status from `DriveModel.busy/status/isRegistered` and the new `DriveModel.monitorState`; "Last sync" from the new `DriveModel.lastChecked` (set when the monitor or a manual Refresh succeeds).
- Row actions: Open in Finder (double-click, menu), Refresh, Free Up Space, Reconnect…, Disconnect… (eject button, menu, context menu) — the same `DriveAction`s and sheets as before.
- Toolbar: filter (name, host, share, user, address, protocol), sort by name, Refresh all, Add menu → SMB share, Connect to URL… (parses `smb://` with `SMBAddress`, then opens the Add sheet prefilled).
- Status strip (the design's transfer strip): shown only while files transfer or a mount operation runs, then the result for 8 seconds before it hides. Measured transfers get a progress bar and a pause button; operations without a measurable total show a spinner. Problems are not shown here: they are in Activity › Needs attention, and settings errors appear in the Settings window.
- Activity: operations in progress, mounts that need attention (with Reconnect…/Retry), saved-mount issues, unsynced changes saved on this Mac after a disconnect (the stored "retained work" locations), and this session's completed operations (`ActivityLog`, built from the status messages the models already publish).
- Settings › General › Updates: Sparkle automatic checks, automatic download, Check Now, version and last check date.
- Settings › Sync & Cache › Clear Cache…: runs Free Up Space on every registered mount (kept-downloaded files are skipped by `PolicyAwareEviction`).
- Settings › Advanced › Remove All…: the existing disconnect-everything flow (`AppModel.prepareForUninstall`) in a "Remove All Mounts" mode without the quit step.
- Uninstall MyDrive…, menu bar extra, ⌘N (Add SMB Share…), ⌘K (Connect to URL…).

## Missing — main window

1. **Other protocols: SFTP, WebDAV, S3** — Add menu items are disabled (`MountKind.isAvailable`), first-launch "Works with" chips list only available kinds, sidebar Protocols rows appear only for kinds that have mounts. Needs: `ConnectionSettings` protocol field, transports, provider support, per-protocol Add sheets. `DriveModel.kind` is hard-coded to `.smb` in `MountPresentation.swift`.
2. **Tailscale discovery** — Add menu › Tailscale peer submenu shows "isn't available yet" and a disabled Scan again; sidebar **Discovered** shows a placeholder; the main table's "Discovered on your tailnet" group and the first-launch "Found on your tailnet" card are not rendered (no data). Needs a discovery service publishing peers (name, address, OS, offered protocols) and a Mount… action that pre-fills the Add sheet.
3. **Online-only and Kept Offline lists** — sidebar items open placeholders (`PlaceholderPane`) and show no counts. Needs the provider/catalog to report per-mount online-only and pinned item counts and lists.
4. **Cached column** — always "—". Needs per-mount local cache size from the provider.
5. **Sidebar Local cache card** — shows "—" and an empty bar; clicking it opens Settings › Sync & Cache (wired). Needs total cache usage and the cache limit.
6. **Per-file transfer progress** — the design's inline row progress ("62 %", "Syncing…" with a bar) and the bottom transfer strip ("Uploading to …, 12 files · 312 of 504 MB, 48.2 MB/s · 4 s left", pause button) need per-file/aggregate transfer events from the File Provider extension. Today the strip shows the current operation with an indeterminate bar, and the status column shows a spinner with the operation's message.
7. **Pause / resume sync** — not available anywhere (strip pause button, Activity "Pause All" and group "Pause").

## Missing — Add SMB mount sheet (03.8, 03.9)

Wired: Address / Share / Username / Password / Name fields, pasting an `smb://server/share` address fills the share (and follows later address edits until the share is typed by hand), the Name placeholder follows the share, Mount stays disabled until address, share, username and password are present, Return mounts, Esc cancels, the Reconnect variant (read-only server, share and user; password only), the connecting footer with progress, and inline errors. Errors are placed by type: `SMBAddressError` share cases and `SMBClientError.itemMissing` / `.permissionDenied` under Share, other address errors and `.serverUnreachable` under Address, `.authenticationRequired` under Password; anything else appears below the form. `DriveModel.connectStep`/`connectFailure` and `AppModel.connecting`/`addFailure` were added so the sheet can show this.

21. **Guest sign-in** — the "Guest" segment is disabled. Needs `ConnectionStore.validate` and `SystemDriveConnectionBackend.verify` to accept an account-less connection, a guest/anonymous session in the Rust SMB transport, and no Keychain item for it.
22. **Share list** — the chevron in the Share field opens a menu that says listing isn't available. Needs share enumeration (SRVSVC `NetShareEnum` over DCE/RPC) in the transport and a host call that lists shares after sign-in, then fills the menu.
23. **"Files: Keep downloaded" per mount** — the Files pop-up offers only Online-only (the current behaviour); "Keep downloaded" is disabled. Needs a per-mount default policy (keep the whole domain downloaded) in the provider.
24. **Cancel while connecting** — the design keeps Cancel enabled; the app keeps the previous behaviour and disables it while a connection runs, because cancelling during Finder registration can leave a saved but unregistered mount. Needs cancellation that rolls back cleanly.
25. **Three connection steps** — the design shows "find the server, sign in, add to Finder". The backend verifies reachability and credentials in one call, so the footer shows two steps (`DriveModel.connectStep` 1 and 2). Splitting verification would allow three.
26. **Errors without a type** — transport `remoteFailure(String)` and other untyped failures can't be attached to a field and appear below the form.
27. **Select the new mount after adding** — the design's notes say the sheet closes and the new mount is selected in All Mounts; selection is not changed today.
28. **Tailscale peer › Mount…** entry point with the address filled in — depends on Tailscale discovery (item 2).

## Missing — Activity (03.1, 03.5)

8. **Per-file rows** (file type tile, file name, folder · size, per-file progress %, speed, Uploading/Downloading/Waiting) — rows are currently mount operations and issues. The **Uploading / Downloading / Queued** segments are disabled.
9. **Conflict rows with Resolve…** and **Retry for failed files** — needs conflict and failure events per file.
10. **Speed** column and summary ↑/↓ speeds — "—".
11. **"Today" totals** on the up-to-date screen (files synced, uploaded, downloaded) — "—".
12. **Persistent history** — `ActivityLog` is in-memory for the current session only (max 200 entries). "Completed today" is cleared on relaunch.
13. "Show Completed Transfers" was renamed **Show Completed Activity** because it shows operations, not file transfers; rename back when file transfers exist.

## Missing — Settings (03.6, 03.7)

All of these are disabled controls showing the app's current fixed behaviour (`FixedToggle`, `FixedChoice`, disabled buttons in `SettingsView.swift`):

14. General: Launch at login (off), Show in menu bar (always on), Show icon in Dock (always on).
15. Finder: Show mounts in Finder sidebar (always on — File Provider), Open in Finder after mounting (off), Reconnect after sleep or network change (off; the monitor only retries every 30 s with back-off up to 5 min).
16. Notifications: Sync conflicts, Connection lost or restored, Large transfer finished (all off; no notifications exist).
17. Sync & Cache: "Files are" (fixed Online-only), "When a file changes in two places" (fixed Keep both copies — conflict copies already exist), cache usage breakdown (Cache / Kept offline / Free), Maximum cache size slider (5–100 GB), Free up space when the disk is almost full, Remove cached files not opened for …, Never sync exclusion list (none exist) and Edit….
18. Network: download/upload speed limits and schedule, pause on Low Data Mode / hotspot / low battery, simultaneous transfers (fixed at 4 for folder imports), retry interval (fixed 30 s with back-off), Tailscale discovery toggle, status line and protocol filter chips.
19. Advanced: Export/Import profiles, Import from Mountain Duck, Open Keychain Access (production credentials live in a shared Keychain group, development credentials in the provider — decide what this button should open), Default SSH key (needs SFTP), Verbose logging, Logs › Show in Finder (no log location yet), Rebuild Finder integration (re-register every domain).
20. Per-mount "Info panel" referenced by the design (credentials, path, online-only mode, bandwidth override, mount-specific exclusions) does not exist.

## Design deviations to review

- **Fonts:** the design uses Inter and Geist Mono as stand-ins for the macOS system fonts (its text styles are named "macOS/Body" etc.). The app uses SF Pro and SF Mono through the matching macOS text styles (`Typography` in `DesignSystem.swift`), so Dynamic Type and system rendering apply. Bundle Inter/Geist Mono only if that is a deliberate brand choice.
- **Accent colour:** the design's `accent` token is system blue, so `Palette.accent` follows the user's macOS accent colour (identical to the design with the default accent).
- **Window chrome:** the window hides the system title bar and draws the design's 52 pt sidebar/toolbar band; `WindowChrome.swift` moves the traffic lights into that band. Re-check after major macOS updates.
- **Settings tabs** use the native SwiftUI `Settings` + `TabView` toolbar (as the design describes); grouped `Form`s supply the boxed rows.
- Terminology follows the design ("mount") in new UI; existing confirmation and uninstall texts keep "drive".
