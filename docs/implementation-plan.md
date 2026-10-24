# Telemessage — implementation plan

Status: planning only. Date: 2026-10-24. Product and architecture: [design.md](design.md).

The workspace starts empty. This plan produces a native AppKit application in incremental, demonstrable stages. No application implementation is included in this documentation step.

## 1. Prove the native dependencies

Tasks:

- Create a minimal macOS AppKit executable and reproducible Xcode build configuration, targeting macOS 13 and Apple Silicon initially.
- Pin a TDLib commit and matching schema; build/package its native library and module map without machine-specific library paths.
- Exercise client creation, one request/response, ordered receives, and graceful closure through a Swift bridge.
- Build isolated AppKit render samples for WebP, TGS, and WebM/VP9 stickers with transparency. Check light/dark backgrounds, looping, corrupt input, and stopping playback offscreen.
- Choose decoder/animation dependencies based on results; record revisions, build instructions, notices, and any minimum-OS changes.

Exit criteria: a clean checkout builds; the bridge runs; all three sticker categories render correctly; native library loading works in an app bundle. Do not defer a required sticker format behind a permanent placeholder.

## 2. Implement account access and ordered state

Depends on stage 1.

Tasks:

- Implement `TDLibClient`, typed transport models, request correlation, one ordered reducer, and a mock transport.
- Add account-specific data directories and Keychain key handling; provide a configuration template for Telegram API credentials.
- Implement state-driven sign-in for phone/code, two-step verification, email, and QR where available. Show clear recovery for unsupported account-creation or new authorization states; never silently loop.
- Add session restoration, connection status, logout cleanup, and graceful app termination.
- Treat timeout, cancellation, auth loss, and shutdown as explicit request lifecycle events.

Exit criteria: sign in with a test account, quit/relaunch without another login, recover from a failed code, and log out cleanly. Automated fixtures cover authorization transitions, update ordering, exactly-once continuation completion, and identifier decoding.

## 3. Build the selected-chat experience

Depends on stage 2.

Tasks:

- Discover contacts and eligible chats across main/archive lists, with loading and pagination.
- Build the “Choose chats” sheet with search, selection, and save/cancel behavior. Distinguish contacts without an existing conversation; resolve chat IDs before saving.
- Add the selected-chat list, local search, manual reordering, unread counts, and empty state.
- Implement account-scoped persistence and a shared `SelectionPolicy` used by every presentation entry point.
- Handle selection removal, inaccessible groups, and group migration. Identify and explain unsupported forum groups/channels.

Exit criteria: selected chats alone survive relaunch and appear in the main UI. Tests prove that unrelated updates do not leak into the list, badges, window restoration, or notification routes. Selection changes leave Telegram membership and archive state unchanged.

## 4. Deliver text chat in independent windows

Depends on stage 3.

Tasks:

- Add `ChatWindowCoordinator`, one window per chat, focus-existing behavior, frame restoration, and optional floating level.
- Build reusable message rows, paginated history, sender metadata, formatted text, reply previews/composition, and sending/read state.
- Add the native composer, IME-safe shortcuts, draft persistence, and text sending.
- Merge history and live events without duplicates; handle message edits/deletions and outgoing ID replacement.
- Add visible-message read reporting, scroll anchoring, and new-message indicators.

Exit criteria: three windows can send/receive independently; closing the main window keeps them usable. Pagination does not jump the viewport. Background windows do not mark new messages read. Lost connectivity does not lose drafts or cause repeated sends.

## 5. Add incoming media and sticker playback

Depends on stages 1 and 4.

Tasks:

- Build shared file state, prioritized downloads, thumbnail caching, and progress/cancel/retry UI.
- Add photo previews/viewer, video poster/playback, visible-only animation, and all three sticker renderers proven in stage 1.
- Add basic audio playback, document cards, service-message descriptions, and unknown-content fallback rows.
- Bound image decode dimensions, animation buffers, concurrent work, and cache storage. Stop playback on window close and row reuse.
- Handle expired media and download failure; honor content restrictions and avoid automatic external file opening.

Exit criteria: a media fixture conversation displays photos, video, animation, WebP, TGS, and WebM stickers with correct sizing/transparency. Malformed files fail locally without breaking scrolling or other windows. Media decoding never blocks the main thread.

## 6. Add photo and video sending

Depends on stage 5.

Tasks:

- Support `NSOpenPanel`, drag-and-drop, and image paste into an attachment preview tray.
- Stage app-owned copies, inspect content, prepare thumbnails, and preserve captions and ordering.
- Implement photo sending, compatible video preparation/sending, and original-document fallback.
- Support multiple attachments and valid album combinations, with understandable partial failures.
- Reconcile upload progress and final message IDs; distinguish preparation cancellation from cancellation after submission.
- Retain upload inputs across restarts until reconciliation confirms they can be deleted. Provide explicit retry only for known failed items.

Exit criteria: send a photo and video with captions from each input method, then verify receipt on another Telegram client. Test a mixed batch, an interrupted large upload, restart during upload, permission loss, and unsupported media. Confirm no duplicate send after an ambiguous timeout.

## 7. Finish attention controls and macOS behavior

Depends on stages 3–6.

Tasks:

- Implement selected-chat-only notifications and Dock badge, respecting mute settings and preview privacy.
- Revalidate selection on notification click and deep links; remove stale notifications on deselection/logout.
- Finish menus, shortcuts, VoiceOver, keyboard focus, dark mode, Reduce Motion, and narrow-window layouts.
- Add settings for selection, media cache, notification previews, and logout.
- Test sleep/wake, reconnect, session revocation, window restoration, and cleanup.

Exit criteria: excluded chats never surface through local alerts, badge counts, or stale window links. An active conversation does not generate redundant alerts. Keyboard and accessibility workflows cover login, selection, reading, and sending.

## 8. Validate and package the first release

Depends on all previous stages.

Tasks:

- Run automated domain/transport tests and focused AppKit UI smoke tests.
- Run live integration checks using a dedicated account and consenting test recipients; no automated messages to personal contacts.
- Profile scrolling, decoding, warm-window latency, and memory with multiple open media-heavy chats; document fixture sizes and hardware.
- Validate sandboxed file staging, clean-machine library loading, cache cleanup, and session persistence.
- Produce a signed/notarized direct-distribution build when credentials are available. Verify Intel separately before advertising universal support.
- Write setup, build, supported-content, and known-limitations documentation; record third-party notices and review Telegram's current distribution requirements before release.

Exit criteria: every first-release criterion in the design passes, or a documented scope change is explicitly accepted. A local unsigned developer build does not count as a distributable release.

## Proposed source layout

```text
Telemessage.xcodeproj
Telemessage/
  App/                 AppDelegate, coordinators, menus
  Telegram/            TDLib bridge, transport models, reducer, services
  Domain/              IDs, messages, selection and notification policy
  Persistence/         Keychain, account state, drafts, window state
  UI/
    Authentication/
    ChatPicker/
    ChatList/
    ChatWindow/
    MessageViews/
    Settings/
  Media/               staging, file cache, decoders, sticker renderers
  Resources/
TelemessageTests/       domain and transport fixtures
TelemessageUITests/     critical native workflows
Vendor/                dependency manifest and library integration
Scripts/               repeatable dependency build/package commands
Config/                checked-in template; ignored developer values
docs/
```

## Verification priorities

| Risk | Verification |
| --- | --- |
| Unselected content appears | One policy tested against list, badge, notification, deep-link and window restoration paths |
| Out-of-order updates or duplicate sends | Replay recorded event sequences, interleave history/live data, simulate delayed acknowledgments |
| Sticker format incompatibility | Stage-1 render fixtures for all formats, transparency and malformed files |
| Native dependency packaging | Clean-checkout builds and app-bundle launch without local package-manager libraries |
| Broken uploads after restart | Staged-file retention plus reconciliation against SDK state |
| Memory growth or UI stalls | Multiple long histories with large images and animated media, repeated window open/close |
| Sensitive data persists incorrectly | Inspect logout cleanup, Keychain use, logs, account boundaries and staging retention |

The first implementation step is stage 1. The largest technical uncertainty is media/sticker rendering and native packaging, so it is resolved before investing in the full conversation UI.
