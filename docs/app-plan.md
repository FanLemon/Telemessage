# Telemessage — app build plan

Status: M0–M7 implemented; awaiting live testing with a real account. Date: 2026-10-24. Product intent: [design.md](design.md). Original staged plan: [implementation-plan.md](implementation-plan.md).

This plan adapts the design to the Xcode project in `app/Telemessage` and to what the TDLib CLI (`cli/`) proved: TDLib 1.8.69 builds locally (`tdlib/build.sh`), loads from Swift, and drives login through authorization-state updates.

## Decisions

| # | Decision | Outcome |
| --- | --- | --- |
| 1 | Product shape | Build design.md's product directly: a compact list of picked chats plus independent pop-out chat windows. No full Telegram inbox in the normal UI. |
| 2 | Deployment target | Keep macOS 27.0 (supersedes design.md's 13+). Newer AppKit/Swift APIs may be used freely. |
| 3 | Storyboard | Keep `Main.storyboard` for the main menu only (standard Edit menu: copy, paste, undo). All windows are built in code. |

## Project baseline and required changes

| Current state | Change |
| --- | --- |
| Storyboard with window and view controller scenes | Remove the window/view controller scenes; keep the menu |
| `MACOSX_DEPLOYMENT_TARGET = 27.0` | Keep (decision 2) |
| App Sandbox on, outgoing network off | Set `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` or TDLib cannot connect |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Keep; the TDLib bridge is explicitly `nonisolated` and owns its own receive thread |
| Folder-synchronized project (`project.xcproj`) | Files added under `Telemessage/` join the target automatically |

TDLib linking: link the static libraries (`libtdjson_static.a`, the other `libtd*.a`) plus static OpenSSL, all collected into the root `libs/` folder by `build-libs.sh`. Nothing is embedded or separately signed, and the app has no external library paths. This needs only build settings (library search paths, linker flags) and a module map like the CLI's.

API credentials: a gitignored `TelegramSecrets.plist` in the app folder. If it is missing the app shows a clear error instead of failing silently.

## Architecture

```text
td_receive thread ──► TDLibClient ──► one ordered event stream ──► TelegramStore (main actor)
   (blocking)        decode JSON →      responses AND updates          users, chats, messages, files
                     typed events       in arrival order                     │ change events
                                                                             ▼
      LoginWindow · MainWindow (picked chats) · ChatPicker sheet · ChatWindows (one per chat)
```

- **`TDLibClient`**: background receive thread; `send(request) async throws -> Response`, correlated by `@extra`. Responses travel through the same ordered stream as updates, so every update that arrived before a response has been applied when the awaiting code resumes.
- **Typed models**: hand-written `Codable` types for the subset of `td_api.tl` in use, decoded by `@type`. An `unknown` case keeps new message types from crashing the app. 64-bit fields encoded as strings (for example chat position `order`) are decoded accordingly.
- **`TelegramStore`**: single owner of Telegram state on the main actor. Reduces new/changed chats, chat positions, read state, message add/edit/delete, temporary→final message IDs on send success, and file progress. Emits fine-grained change events; table views apply them as diffs.
- **Services**:
  - `AuthService`: authorization steps.
  - `ChatListService`: `loadChats` for main and archive lists, `getContacts`, `createPrivateChat`; feeds the picker.
- **`SelectionStore` / `SelectionPolicy`**: the account-scoped, persisted set of picked chats with manual order. Every presentation path asks the policy: list, window opening/restoration, notifications, Dock badge, automatic media downloads.
  - `ConversationService`: history paging, sending, `openChat`/`closeChat`/`viewMessages` for correct read receipts.
  - `FileService`: deduplicated downloads with visible rows first; uploads.

## UI

Layout follows design.md:

```text
Telemessage                         Chat: Design team
┌───────────────────────────┐       ┌─────────────────────────────────┐
│ Search picked chats    +  │       │ Design team       Keep on top ○ │
├───────────────────────────┤       ├─────────────────────────────────┤
│ (A) Alex            2     │       │            ── Today ──          │
│ (D) Design team     5     │ ───►  │ Alex · 10:42                    │
│ (F) Family                │       │ [Photo preview]                 │
│                           │       │ Here is the latest version.     │
│                           │       │                looks good ✓✓    │
├───────────────────────────┤       ├─────────────────────────────────┤
│ Manage chats     Settings │       │ ↩ Replying to Alex …         ✕  │
└───────────────────────────┘       │ 📎  Message…              Send   │
                                    └─────────────────────────────────┘
```

- **Login window**: phone, code, 2FA password and email steps driven by authorization state, as in the CLI. QR login rendered with CoreImage. Clear messages for unsupported states (sign-up, required Premium purchase).
- **Main window**: compact `NSTableView` of picked chats: avatar (photo, or initials on a color), title, unread badge, muted icon. Local search, manual drag reordering. With nothing picked it shows "Choose chats". The window subtitle shows connection state (Connecting… / Updating…). Closing it leaves chat windows and the app running.
- **Chat picker sheet** ("Manage chats" / +): searchable list of contacts and eligible chats from main and archive lists — private chats, basic groups, non-channel supergroups. Checkboxes, Save/Cancel. Contacts without a chat get one via `createPrivateChat` before saving. Channels and forum groups are shown as unavailable with the reason.
- **Chat windows**: `ChatWindowCoordinator` keeps one window per chat; reopening focuses the existing one. Default 440 × 640, minimum 340 × 420, frame restored per chat, optional "Keep on top" (floating level). Double-click or Return in the main list opens a chat. Incoming messages never open or focus windows.
- **Conversation**: variable-height `NSTableView` of bubbles with date separators, sender names in groups, reply previews, and sending/sent/read/failed state.
  - Older history loads near the top while keeping the scroll anchor.
  - Auto-scroll only when already at the bottom; otherwise show a "new messages ↓" button.
  - Mark read only when the app is active, that window is key and the messages are on screen. Background windows never mark read.
- **Composer**: growing `NSTextView`. Return sends, Shift-Return inserts a newline, and text still being composed by an input method is never sent. Attach button, drag-and-drop, paste, per-chat drafts kept when windows close.

## Building

1. `./build-libs.sh -b` at the project root:
   - runs `tdlib/build.sh -b` (gperf, cmake, OpenSSL, then TDLib itself, installed into `tdlib/td/tdlib`);
   - runs `medialibs/build.sh -b` (rlottie for TGS stickers, libvpx for VP9/WebM stickers). rlottie is pinned to a master commit (its last release is from 2020) and built without its ARM NEON path, which needs assembly its CMake only builds for 32-bit ARM;
   - copies the headers and static libraries the app and the CLI link into `libs/` (with a `VERSIONS` file). `--force` rebuilds even when `libs/` is complete; `--collect` only copies.

   Build folders are kept. `./build-libs.sh -c` (alone or with `-b`) removes them once `libs/` is complete: `tdlib/packages`, `tdlib/workspace`, the `tdlib/td` source and build, `medialibs/packages` and `medialibs/workspace`. A later rebuild then starts from scratch and clones TDLib again.
3. Copy `app/Telemessage/Config/TelegramSecrets.example.plist` to `app/Telemessage/Telemessage/TelegramSecrets.plist` and fill in the API ID and hash (gitignored).
4. Open `app/Telemessage/Telemessage.xcodeproj` and run. Everything links statically from `libs/` (`LIBS_PREFIX`); the app depends only on system libraries.

## Verification

The app's code (everything except `App/`) also builds as a Swift package from `app/Telemessage/Package.swift`, with the same concurrency settings as the app target.

- `swift test` runs the unit tests in `TelemessageTests`: JSON coding against the pinned schema, client ordering and shutdown, the store reducer, selection and policy, history paging and read reporting against a fake TDLib, message layout, drafts encryption, attachment preparation (including MOV→MP4), album grouping, staging retention across restarts, notification filtering and the Dock badge, gzip/TGS rendering and VP9-with-alpha decoding checked pixel by pixel. Fixtures are synthetic (`TelemessageTests/Fixtures`: a hand-written Lottie file, ffmpeg-generated WebM and MOV clips); no real account data.
- `swift run TelemessageSnapshots <dir> [scene]` renders windows offscreen with a fictional sample account to PNGs (light and dark) for visual review: sign-in steps, chat list, picker, conversations with media, the attachment tray and settings.

Live behavior with a real account is checked by hand; see the checklist below.

### Live test checklist

- Sign in with phone + code, with two-step verification, and by QR code; quit and relaunch without signing in again.
- Pick a few chats (including an archived chat and a contact without a chat); only they appear; reorder by dragging; relaunch keeps order.
- Open three chat windows, close the main window, keep chatting; reopening a chat focuses its window; "Keep on Top" survives relaunch; open windows come back after relaunch.
- Scroll up through long history without jumps; new messages while scrolled up show the "new messages" button.
- Messages in a background window stay unread on your phone until that window is focused.
- Receive photos, videos, GIFs, documents, voice messages, static/animated (TGS)/video (WebM) stickers.
- Send text (Return / Shift-Return, Chinese/Japanese input), a reply, photos and videos with a caption, an album, a file, "Send as files", paste a screenshot, drag files in; cancel an upload; retry a failed send without a duplicate.
- Notifications (turn on in Settings): only picked, unmuted chats; none for the focused chat; they disappear when read on the phone; clicking opens the chat.
- Dock badge counts only picked, unmuted chats.
- Sleep/wake and Wi-Fi off/on reconnect; Log Out removes picked chats, drafts and downloads.

## Known limitations

- Voice messages are Ogg/Opus; if macOS can't decode them, the card offers "Show in Finder" instead of playing.
- Videos download fully before playing (no streaming).
- Channels, forum groups and secret chats can't be picked.
- Not implemented: editing or deleting your sent messages (only failed sends can be deleted), reactions, search, drafts synced to other devices, notifications while the app isn't running.
- Built and tested for Apple Silicon only; signing/notarization for distribution not set up.

## Milestones

Each milestone ends in something runnable.

| # | Milestone | Demo |
| --- | --- | --- |
| ✅ M0 | Project setup: static TDLib linking, module map, network entitlement, secrets plist, menu-only storyboard, deployment target | App launches and logs "TDLib 1.8.69" |
| ✅ M1 | Core: `TDLibClient`, typed models, `TelegramStore`, test target with recorded JSON fixtures | Tests cover decoding, ordering, temporary→final message IDs |
| ✅ M2 | Login window (including QR), session restore, logout | Log in, quit, relaunch, still logged in |
| ✅ M3 | Selection: chat picker sheet, `SelectionStore` persistence, `SelectionPolicy`, picked-chat main window with unread counts, search, reordering, empty state | Pick two chats; only they appear, including after relaunch |
| ✅ M4 | Chat windows with text conversation: one window per chat, frame restore, keep-on-top, history paging, bubbles, live/edit/delete, send, replies, read receipts, drafts | Three windows chatting independently; main window closed |
| ✅ M5 | Incoming media: photos, video/GIF (`AVPlayerView`), static WebP stickers (native ImageIO), documents, voice, fallback card for unknown content | Media-heavy chats render |
| ✅ M5b | Animated stickers: spike to choose TGS (rlottie) and WebM (libvpx) renderers | All three sticker types play |
| ✅ M6 | Sending media: photos, videos, files, captions, albums, upload progress, retry without duplicate sends | Photo and video arrive on another device |
| ✅ M7 | Attention and Mac polish: notifications and Dock badge for picked chats only, selection rechecked on notification click, menus/shortcuts, dark mode, VoiceOver, sleep/wake recovery | Day-to-day usable |

Change from [implementation-plan.md](implementation-plan.md): that plan proves sticker rendering first. Here animated stickers move to M5b so a usable client exists sooner. They sit behind one sticker view contract, so deferring them does not put earlier work at risk. All other first-release requirements in design.md still apply.
