# iSyncer 1.0

iSyncer is a native macOS music player and media library with USB sync for iPod Classics running Apple firmware. Version 1.0 brings together library management, playback, podcasts, audiobooks, TV, movies, and iPod syncing in a classic iTunes-inspired interface.

## Download

Download **iSyncer-1.0.0.zip**, unzip it, and move **iSyncer.app** to Applications.

- **Apple silicon**, macOS **14 or later**.
- Includes a standalone **FFmpeg** helper; Homebrew is not required for conversion.
- The app is ad-hoc signed and unnotarized. macOS may require approval in **System Settings → Privacy & Security → Open Anyway** after the first launch attempt.
- Existing iSyncer libraries migrate automatically. You can save a library backup from **File → Library Backup & Export** before upgrading.

## Added since 0.6

### Library and artwork

- **Multiple media folders:** add, remove, and rescan folders in **Settings → Library**, including folders on external drives. Playlists can span folders, and identical relative filenames remain distinct.
- Unavailable sources retain their indexed entries and pause automatic iPod removals and playlist reconciliation. Removing a source leaves its files on disk.
- **Artist pages:** chronological albums and linked artist names and aliases, stored in iSyncer’s library data.
- **Artwork galleries:** collect front covers, back covers, and disc images; select the cover used by the player and iPod sync.
- **Album artwork sizing:** a slider beneath the cover grid remembers your preferred size.
- **Library backup and restore:** preserves library metadata, playlists, ratings, listening history, bookmarks, video metadata, artist links, galleries, and iPod sync settings. Restore saves the current setup first. Media files are backed up separately.
- **M3U8 playlist export** from the File menu.

### Playback and appearance

- **Expanded Now Playing:** large artwork, an artwork-tinted background, transport controls, seeking, queue, and lyrics.
- A **Settings cogwheel** in the bottom toolbar.
- Consistent pane-header heights and section bars across Music, Audiobooks, Podcasts, and Videos.
- Podcast controls below Shows, glossy video section headers, and the sidebar source renamed to **Music**.
- Corrected the CD spindle position in the app icon.

### iPod syncing and conversion

- **ALAC/FLAC → AAC conversion** at 128, 192, 256, or 320 kbps, retaining the originals on the Mac.
- **Per-album quality overrides**, saved separately for each iPod, with transfer-size estimates.
- **Parallel audio and video preparation** with an adjustable shared job limit.
- A bundled FFmpeg helper, including license notices, build instructions, configuration, and corresponding upstream source.
- A configurable **conversion-cache location**, with the option to move existing encodes. Library scans ignore iSyncer’s conversion cache.
- Bring the running app forward and select an iPod when it connects.
- An optional, reversible **Finder auto-opening setting** using macOS’s automatic device-sync preference. This affects automatic syncing for other Apple devices too; manual Finder access remains available. Reconnecting, or logging out and back in, may be necessary.
- Repeated listens on the iPod create **separate Last.fm scrobbles**, with earlier timestamps estimated from the latest recorded play.

### Podcasts

- Browse followed shows’ **RSS episode catalogs**, filter downloaded episodes, and fetch older episodes.
- Set a default **iPod episode limit** and override it for individual shows.
- Set separate **Mac download limits** for each followed show.
- Sync Preview identifies removals containing saved progress and shows the space they recover.

## Existing core features

Music, video, podcast, and audiobook playback; playlists and smart playlists; a column browser and Cover Flow; a Mini Player; queue, shuffle, repeat, ReplayGain, equalizer, and visualizer; synced and plain lyrics with lookup; TV and movie metadata lookup and editing; collapsible TV seasons and Up Next; automatic two-way playback-progress reconciliation during sync with conflict selection; Discord Rich Presence; Last.fm scrobbling; and detailed iPod sync previews and results.

## Validation and current limits

- The 30-test automated suite covers library migration, cross-folder playlists, unavailable sources, history preservation, TV metadata, encoding settings, playback reconciliation, scrobbling, and device-database operations.
- The packaged app includes FFmpeg and is checked for code-signature and ZIP integrity.
- Physical iPod testing of the newest selected-gallery-cover and per-album-quality changes is still outstanding.
- Finder auto-opening suppression depends on macOS behaviour and needs verification on the target Mac.
- Stock firmware restoration is not included.

See the README for setup, service credentials, and library naming conventions, and CHANGELOG.md for the intermediate development-build notes.
