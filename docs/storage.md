## Data locations

### Telemessage app (sandboxed)

Everything lives in the app's sandbox container:

```
~/Library/Containers/com.Farsonic.Telemessage/Data/Library/Application Support/Accounts/primary/
├── db/              TDLib database (messages, chats, session), encrypted with a Keychain key
├── files/           Downloaded media cache (TDLib)
│   ├── photos/  videos/  animations/  documents/  music/  voice/  video_notes/
│   ├── stickers/  thumbnails/  profile_photos/  temp/
├── App/
│   ├── selection.json   Picked chats and their order
│   ├── windows.json     Open chat windows, frames, keep-on-top
│   ├── drafts.bin       Unsent drafts (AES-GCM encrypted)
│   └── staging.json     Which staged uploads belong to which messages
└── Staging/         Copies of outgoing attachments until they finish sending
```

Also stored:

- **Settings** (notifications, previews, auto-download) and the main window position: `~/Library/Containers/com.Farsonic.Telemessage/Data/Library/Preferences/com.Farsonic.Telemessage.plist`
- **Encryption keys** in the Keychain, service `com.Farsonic.Telemessage.tdlib-database-key`, accounts `primary` (database) and `primary.drafts` (drafts).
- **Decoded images** are cached in memory only, never written to disk.

**Cached media** is in `…/Accounts/primary/files/`. Settings › Clear Downloads empties it; Log Out deletes the whole `Accounts/primary` folder and both Keychain keys.

macOS blocks other apps (including Terminal tools) from listing the container; open it in Finder instead:

```bash
open ~/Library/Containers/com.Farsonic.Telemessage/Data/Library/Application\ Support/Accounts/primary
```

### CLI (`cli/`, not sandboxed)

```
~/Library/Application Support/TelemessageCLI/
├── db/      TDLib database, unencrypted (empty key)
└── files/   Downloaded media cache (the CLI doesn't download media, so it stays empty)
```

Delete this folder to sign the CLI out and start fresh.