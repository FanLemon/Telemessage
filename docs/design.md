# Telemessage — macOS chat app design

Status: proposed design, before implementation. Date: 2026-10-24.

## Product intent

Build a small, native Telegram client for Mac that keeps attention on a few chosen people and groups. Use Swift and AppKit throughout, with independent pop-out chat windows, rich incoming media, and photo/video sending.

“Picked contacts and groups” means an explicit, persistent selection made inside this app. The normal interface shows only that selection. A separate management screen exposes other eligible conversations so the user can change it.

“Pop chat window” means a resizable standalone conversation window that stays open independently of the main window. Always-on-top is an optional per-window setting. Incoming messages do not steal focus or automatically open windows.

## Proposed first-release scope

| Area | First release |
| --- | --- |
| Platform | macOS 13+, initially Apple Silicon; Intel packaging after dependency validation |
| UI | Programmatic AppKit, Auto Layout, native menus and keyboard shortcuts; no SwiftUI |
| Account | One existing Telegram user account, persistent login, logout |
| Selection | Contacts/private chats, basic groups, and non-channel supergroups |
| Windows | Compact selected-chat list and one reusable pop-out window per chat |
| Conversation | Paginated history, live messages, sender names, timestamps, read/sending state, replies |
| Receive media | Photos, video, animations, static/animated/video stickers; basic audio and file cards |
| Send media | Text, photos, videos, captions, and multiple attachments |
| Attention | Notifications and Dock unread count restricted to selected chats |
| Persistence | Selected chats, manual ordering, window frames, drafts, preferences |

Deferred: multiple accounts, secret chats, calls, stories, channel browsing, sticker creation/sending UI, full reaction UI, group administration, global message search, and video editing. Forum-topic navigation is deferred; forum groups receive an explicit “Open in Telegram” affordance and are excluded from selectable groups until topic-aware sending is implemented. Unknown message types remain visible as descriptive fallback cards.

## User experience

### Setup and selecting conversations

1. Launch into a native sign-in window. Follow the authentication steps actually requested by Telegram, including phone/code, password, and email steps when applicable. Offer QR login where supported.
2. After authentication, show “Choose chats.” Search existing chats and Telegram contacts, including archived conversations. Do not import the Mac address book.
3. Check people/groups and save. For a contact without an existing chat, resolve its private chat before persisting the selection.
4. Show the selected-chat list. With no selection, show “Choose chats” rather than the full Telegram inbox.

Selection is local to Telemessage and does not change Telegram folders, pins, archive state, membership, or notification settings on other devices. Removing a selection does not leave a group or delete messages. Removing a chat closes its windows, removes pending/delivered local notifications for it, and stops its automatic media work. Recheck selection when handling an old notification or restored window.

### Main window and pop-out windows

```text
Telemessage                         Chat: Design team
┌───────────────────────────┐       ┌─────────────────────────────────┐
│ Search selected chats  +  │       │ Design team       Keep on top ○ │
├───────────────────────────┤       ├─────────────────────────────────┤
│ Alex                  2   │       │ Alex · 10:42                    │
│ Design team           5   │ ───►  │ [Photo preview]                 │
│ Family                    │       │ Here is the latest version.     │
│                           │       │                [Video preview]  │
├───────────────────────────┤       ├─────────────────────────────────┤
│ Manage chats     Settings │       │ [Attachment previews]           │
└───────────────────────────┘       │ +  Message…              Send   │
                                    └─────────────────────────────────┘
```

Double-click a row or press Return to open/focus its window. Several different chat windows can coexist. Closing the main window leaves chats and the application running; quitting ends background operation. Restore only previously open chats that are still selected.

Use an `NSWindowController` registry keyed by account and chat ID. Use ordinary `NSWindow` instances for keyboard input, accessibility, and standard macOS behavior; set floating level only when the user enables “Keep on top.” Proposed default chat size: 440 × 640 points; minimum: 340 × 420.

The timeline initially loads recent messages and fetches older history near the top. Keep the scroll anchor during pagination and media resizing. Auto-scroll only when already near the bottom; otherwise show a new-message indicator. Mark messages read only while the app is active and that conversation is key, visible, and displaying the messages. Opening or preloading history alone must not mark it read.

The composer uses `NSTextView`: Return sends, Shift-Return inserts a newline, and input-method composition must finish before Return can send. Support file picking, drag-and-drop, and pasted images. Attachments enter a preview tray with captions and removal controls before sending. Keep drafts when windows close.

### Selection as a central policy

All presentation paths consult a shared `SelectionPolicy`: chat list, search results outside the picker, window opening/restoration, notification creation/actions, Dock badges, and automatic media downloads. An external deep link to an unselected chat offers selection first.

This is a presentation and attention filter, not selective Telegram synchronization. TDLib may receive and cache account-wide metadata and updates. The application cannot promise that unselected chats never reach local storage.

## Technical design

### Telegram integration

Use official **TDLib**, which supports macOS and manages Telegram networking and local storage. Its C-compatible interface fits a small Swift adapter. This is a user-account client; a bot integration would not meet the intended account experience. [TDLib overview](https://core.telegram.org/tdlib/)

Build a pinned TDLib revision and its dependencies into a redistributable library bundle with headers/module map. Record the exact revision, API schema, build flags, checksums, and notices. Development and shipping builds must use the same pinned artifact. Do not require an end user to install Homebrew. [Official TDLib repository and build guidance](https://github.com/tdlib/td)

Use `td_create_client_id`, `td_send`, and `td_receive`. A dedicated receive thread copies returned JSON immediately and feeds one ordered processing pipeline. Match responses through `@extra`; preserve update/response order. Close the client before process termination. [TDLib JSON interface](https://core.telegram.org/tdlib/docs/td__json__client_8h.html)

The Swift adapter exposes typed requests and domain events. A serial reducer owns Telegram state; an actor can protect request bookkeeping, but blocking receives never run on the main actor or a cooperative executor. Publish immutable UI snapshots on `MainActor`. Process events sequentially before resuming dependent requests; do not create an independent unstructured task for each event. Cancel/finish pending continuations exactly once during shutdown or authorization loss.

Use schema-aware `Int64` domain identifiers and Codable mappings that respect TDLib's numeric versus string encodings. Retain an unknown-content case to tolerate schema additions. Pinning the schema is required; examples from unrelated wrapper versions are not the integration contract. [JSON serialization rules](https://core.telegram.org/tdlib/docs/td__json__client_8h.html)

### Components and ownership

| Component | Responsibility |
| --- | --- |
| `AppDelegate` / `AppCoordinator` | App lifecycle, menus, login routing, dependency construction |
| `TDLibClient` | Native bridge, receive loop, correlation, errors, orderly shutdown |
| `AuthorizationCoordinator` | Authentication state machine and session transitions |
| `TelegramStore` | Ordered reduction of users, chats, messages, permissions and files |
| `SelectionStore` / `SelectionPolicy` | Account-scoped selection, ordering, presentation decisions |
| `ChatService` | Discovery, paginated history, sending, replies, read reporting |
| `MediaService` | Downloads/uploads, staging, thumbnail decoding and cache budgets |
| `StickerRenderer` | Static, TGS and WebM rendering behind one AppKit view contract |
| `ChatWindowCoordinator` | Window uniqueness, restoration, selection enforcement |
| AppKit controllers | Bind snapshots to native views and forward user intent |
| `NotificationCoordinator` | Deduplication, selected-chat filtering, mute/privacy handling |

Use `NSTableView` for the selected-chat list and a reusable, variable-height `NSTableView` timeline inside `NSScrollView`. Start with this simpler layout; switch the timeline to `NSCollectionView` only if an early media-layout prototype demonstrates a concrete need. `NSStackView`, `NSImageView`, and custom `NSView` subclasses compose message rows. Use `AVPlayerView` for conventional video playback. [Apple AVPlayerView documentation](https://developer.apple.com/documentation/avkit/avplayerview)

### Message and file lifecycle

Authorization is driven by TDLib state updates. Chat discovery/history, message sending, and file progress use its asynchronous API; photo/video requests reference staged local files. Reconcile outgoing temporary messages when delivery updates arrive. [TDLib getting started](https://core.telegram.org/tdlib/getting-started)

Planned API touchpoints are `loadChats`, `getContacts`, `createPrivateChat`, `getChatHistory`, `openChat`/`closeChat`, `viewMessages`, `sendMessage`/`sendMessageAlbum`, `downloadFile`, and file/message updates. Confirm signatures, permitted content combinations, and required fields against the pinned schema during implementation. [TDLib API schema](https://raw.githubusercontent.com/tdlib/td/master/td/generate/scheme/td_api.tl)

Key domain records:

- `SelectedChat`: account ID, chat ID, manual sort order, selection date.
- `MessageKey`: account ID + chat ID + message ID; never message ID alone.
- `MessageViewData`: sender, formatted text, content, reply reference, timestamps, sending/read state.
- `AttachmentDraft`: staged file URL, detected media type, caption, preparation state.
- `ChatWindowState`: chat ID, frame, floating preference, scroll anchor.

Merge live updates and history pages by message key. Handle edits, deletions, chat migration, membership changes, and permission changes. Follow a selected basic group's migration to its replacement supergroup without losing selection. Read-only/removed chats retain readable history where available but disable sending with an explanation.

Outgoing items move through preparing → submitting → pending/uploading → sent or failed. Do not blindly resubmit after a UI timeout: delivery may still complete. Reconcile SDK state first; explicit retries must not create a second send while the first remains unresolved. Persist staging files until TDLib no longer needs them, including across app restarts. Draft attachment cleanup and active-upload cleanup use different rules.

## Media behavior

Telegram stickers include static images, TGS vector animations, and WebM/VP9 video stickers. These need distinct decoding paths. [Telegram sticker formats](https://core.telegram.org/stickers)

| Content | Rendering / interaction | Sending in first release |
| --- | --- | --- |
| Photo | Downsampled preview; click opens larger image viewer | Yes, with caption; preserve-original file option |
| Video | Poster, duration, download progress, click-to-play controls | Yes; prepare a compatible copy when needed |
| GIF / animation | Loop only while visible; respect Reduce Motion | File attachment; dedicated animation composer deferred |
| Static sticker | Transparent image without message-bubble background | Deferred |
| TGS sticker | Dedicated vector renderer with bounded decompression | Deferred |
| WebM video sticker | Dedicated VP9/alpha-capable decoder and frame renderer | Deferred |
| Audio / voice note | Basic playback controls when decodable; file fallback | Recording deferred |
| Document / other | Name, size, download/open action, descriptive unsupported card | Original-file fallback for attachments |

Do not assume AVFoundation handles every Telegram codec or preserves WebM sticker transparency. Before full UI work, prove static WebP decoding, TGS fidelity, and WebM alpha playback with representative files. Candidate dependencies are libwebp, a TGS-compatible renderer such as rlottie, and libwebm/libvpx for video stickers; final choices depend on the spike's fidelity, packaging, maintenance, and license findings. All required sticker categories must render in the first release; placeholders are error handling, not completion of that requirement.

Use thumbnail-first loading for selected chats. Download larger photos on opening them and videos on explicit playback. Deduplicate requests by file ID; prioritize visible rows, bound decoder work, and stop animations when rows leave the viewport or windows are hidden. Never execute attachments automatically. Handle corrupt files with a retryable error card.

Outgoing files are copied into app-owned staging while authorized file access is available. Inspect actual type and size, preserve orientation, generate previews, and display preparation/upload progress. Offer photo versus original-file sending. Normalize unsupported video into a compatible format with AVFoundation when feasible, or offer sending the original as a document. Multi-file selection preserves order; use albums only for supported combinations, with clear per-item failures.

## Local storage, notifications, and resilience

Store TDLib data under account-specific Application Support directories. Store its database encryption key in Keychain; keep login codes and passwords transient. App configuration supplies the developer's Telegram API ID/hash through an ignored local configuration file during development. Session material must never enter source control or logs.

TDLib owns its message database. The app owns a small versioned selection/preferences file, window restoration, and drafts. Sensitive drafts use encrypted storage with a Keychain-managed key. Downloaded media and upload staging require separate retention controls; database encryption must not be described as encrypting every attachment on disk.

Request notification permission when the user enables notifications. Filter before scheduling, respect chat mute settings, suppress alerts for the actively viewed conversation, and default to hidden message previews. Count unread messages only across selected chats. Notifications work while the app is running; no quit-state background delivery is promised.

Show connection state without blocking cached history. Resume after sleep/reconnect through SDK state reconciliation. A revoked session closes chat views and routes to login. Logout clears account-scoped UI, local notifications, drafts, selection, staging, and local account data after the client has closed. Quit closes the client without logging out.

Use App Sandbox with outgoing network access and user-selected file access, validated against the actual native dependencies. Target a signed/notarized direct-download app first; App Store distribution is a separate milestone.

## Quality targets and release criteria

- Selecting two chats makes every ordinary surface show only those two, including after relaunch and when old notifications are clicked.
- Three chat windows remain responsive during a video upload and history pagination; reopening a chat focuses its existing window.
- Photos, common videos, static stickers, TGS stickers, and transparent video stickers render correctly in real conversations.
- Photo/video sending supports captions, multiple attachments, progress, failures, and reconnect without duplicate delivery.
- No automatic read receipts from background windows or preloaded history; Telegram state remains consistent across devices.
- Keyboard navigation, VoiceOver labels, appearance changes, Reduce Motion, and IME input work.
- Unknown content, expired files, revoked permissions, malformed media, and unavailable codecs cannot crash the timeline.

Proposed performance targets: a warm cached window appears within 300 ms on the reference Apple Silicon Mac; ordinary scrolling targets 60 fps. Instrument before committing memory/cache limits, and record the reference machine and fixture sizes.

## Decisions to revisit after the first spike

The working defaults are macOS 13+, one account, Apple Silicon first, manual ordering, standalone windows, and no unsolicited pop-up windows. They permit implementation to begin without a product-decision blocker. The early spike must settle the native dependency set, minimum supported OS in practice, and Intel build feasibility. Telegram API credentials are needed for live integration testing; signing credentials are needed only for distribution.
