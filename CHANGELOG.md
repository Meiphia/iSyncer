# iSyncer changelog

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
