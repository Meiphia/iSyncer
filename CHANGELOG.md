# iSyncer changelog

## 1.0.0

First major release of iSyncer: a native macOS media player, library manager, and iPod Classic sync app. This release brings together the additions developed in 0.6.1–0.6.8; detailed notes for those builds follow below.

- Combine multiple media folders, browse artist pages with linked aliases, and collect album artwork in galleries.
- Expand Now Playing for large artwork, queue, and lyrics, and resize covers in the album browser.
- Convert ALAC and FLAC to AAC for the iPod, choose quality per device or album, and prepare audio and video in parallel with bundled FFmpeg.
- Choose the conversion-cache location and move existing encodes.
- Browse podcast RSS archives, download older episodes, and set separate Mac and iPod episode limits with per-show overrides.
- Import repeated iPod listens as separate Last.fm scrobbles.
- Back up and restore library metadata, playlists, history, galleries, and sync settings, and export playlists as M3U8.
- Open Settings from the toolbar cogwheel, bring iSyncer forward on iPod connection, and optionally change macOS’s automatic device-sync preference to suppress Finder auto-opening.
- Standardized pane headers and podcast/video section bars, renamed the Music source, and corrected the icon’s CD center.

The download targets Apple silicon Macs running macOS 14 or later. Builds are ad-hoc signed and unnotarized. Physical iPod verification of the newest gallery-cover and album-quality changes remains outstanding; Finder auto-opening behaviour depends on macOS.

## 0.6.8

- Added Settings → Library with a folder list, multi-folder selection, Add, Remove, and Rescan controls. Removing a source leaves its media files on disk.
- Music and videos from multiple folders share one library, with distinct file identities, cross-folder playlists, and support throughout playback, metadata editing, encoding, and iPod sync.
- Unavailable folders retain their indexed entries and pause automatic iPod removals and playlist reconciliation. Reconnecting a source volume triggers a rescan when the library is idle.
- Added an opt-in Finder automatic-opening setting using macOS’s automatic device-sync preference. It preserves the previous preference for restoration and explains its effect on other Apple devices and possible logout requirement.
- Added a Settings cogwheel to the bottom toolbar.

## 0.6.7

- Added artist pages with chronological album browsing and linked artist names and aliases.
- Added a gallery for album artwork with a selected cover for the player and iPod sync.
- Added per-album AAC quality overrides for each iPod, with estimated transfer sizes.
- Added Expanded Now Playing with large artwork, playback controls, queue, lyrics, and an artwork-tinted background.
- Added library backup, restore, and M3U8 playlist export from the File menu. Backups include library history, playlists, video metadata, galleries, artist links, and iPod sync settings.
- Added a saved artwork-size slider below the album cover grid.

## 0.6.6

- Import repeat iPod listens as separate Last.fm scrobbles, estimating earlier timestamps from the latest recorded play.

## 0.6.5

- Set a default iPod podcast episode limit and override it for individual shows. Sync Preview flags removals with saved progress and shows how much space they free.
- Browse a followed show’s RSS catalog, filter to downloaded episodes, and download older episodes. Set a separate download limit on the Mac for each followed show.

## 0.6.4

- Added an option to bring iSyncer forward and select a newly connected iPod while the app is running.

## 0.6.3

- Centered the CD spindle hole in the app icon.

## 0.6.2

- Matched the Music, Audiobooks, Podcasts, and Videos pane headers to the sidebar's Source header.
- Moved the podcast controls below Shows and added glossy section headers to the video poster browser.
- Renamed the Library source to Music.
- Added a custom iPod conversion cache location with the option to move existing encodes. The library scanner skips iSyncer’s cache folders.

## 0.6.1

- Added optional ALAC and FLAC conversion to AAC for iPod music sync. Choose 128, 192, 256, or 320 kbps per iPod.
- Audio and video preparation now shares an adjustable parallel job limit. Prepared files are cached on the Mac and copied to the iPod when you apply the preview.
- Added support for packaging a standalone FFmpeg helper with its build instructions, license, and source.

## 0.6.0

Changes since 0.5.33. The macOS download is for Apple silicon and requires macOS 14 or later.

### TV, movies, and playback

- Open a show in **Videos → Posters** to see **Up Next**. Resume the most recently started unfinished episode at its saved position, or play the first unwatched episode in season order.
- In Posters view, episodes are grouped under collapsible season headers, including Specials. The full-width headers have a disclosure arrow and an outline, and each show remembers which sections you collapse while you browse.
- Edit a TV episode’s season and episode numbers in **Get Info**. Preview the new path, then rename or move the video and its matching NFO, artwork, and subtitle files.
- Use **Organize Season…** to renumber selected episodes in one pass. Start at a chosen episode or apply an offset, review each destination, and catch collisions before files move.
- Store edited video titles, release dates, descriptions, and artwork by file fingerprint so they follow the video after a move or rename. Existing edits migrate as iSyncer rediscovers the files.
- Added **Library Health → TV & Movies** to find missing or duplicate episode numbers, season-folder mismatches, and possible duplicate movies. Open the editor or organizer from the results.

### iPod sync and podcasts

- **Sync Preview** shows separate counts for file copies, removals, metadata and artwork changes, and bookmarks going to the Mac or iPod. The detailed view shows before-and-after bookmark values.
- **Last Results** opens the selected report and shows a clear empty state when there are no changes. The sync footer can use a second row when space is tight.
- When iSyncer recognizes the original transfer, renumbered TV episodes can update their season and episode on the iPod without recopying the file. Their bookmark and play count stay with the existing copy.
- **Catch Up** syncs a chosen number of the newest unplayed podcast episodes per show and keeps in-progress and pinned episodes. Removing completed episodes from the iPod is optional.
- **Continue Listening** moved to the bottom status bar for podcasts and audiobooks. Podcast check progress, downloads, and errors also appear there, and the idle “up to date” message is gone.

### Library and playlists

- **File → Relink Media Folder…** previews matched and missing paths before changing the library location. It keeps library history and pauses automatic iPod removals and playlist updates while files are missing.
- The bottom-left **+** menu offers **Playlist** and **Smart Playlist**.
- Edit built-in smart playlists directly from the sidebar and reset them to their defaults. Smart playlists can use date rules such as “is this month” or “is unset,” sort without a track limit, and opt in or out of iPod sync.

### Appearance

- New blue music-note and silver-CD app icon inspired by classic iTunes.
- **Settings → Appearance → Interface text size** offers Standard, Large, and Extra Large. The sidebar, browser columns, and song table update live, including row and header heights.
- The Mini Player fits more closely around its controls, with a dedicated drag strip beside the traffic lights.
- Video **Get Info** aligns the season and episode fields with the other controls and stacks the artwork buttons so both labels fit.
