# Human-written introduction

This app was entirely vibecoded to solve a very niche problem; syncing an entire media library comprised of music, video, podcasts and audiobooks to an iPod Classic through modern means. Apple Music/Finder is finnicky at best as of today and other solutions out there make compromises to the syncing process that make it arduous and prone to failure. While I appreciate the efforts of those other attempts, it never worked well for me. So I threw the problem at an LLM and let it spin up this as a result. It's very niched for how I personally sort my music library so it might need some readjustments on your own end if you decide to use this.

That said, being vibecoded didn't mean going "computahhh... make itunes again". An LLM is pretty bad at understanding human UX. So, a lot of pre-design went into that so that it would get the actual feel of use right. Anyway. Here's some screenshots:

<table>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/0692dbdc-6dff-405e-8bcb-802e708e401e"><img width="260" alt="iSyncer screenshot 1" src="https://github.com/user-attachments/assets/0692dbdc-6dff-405e-8bcb-802e708e401e"></a></td>
    <td><a href="https://github.com/user-attachments/assets/a16b34f8-7af6-438a-b217-f4bb184f3964"><img width="260" alt="iSyncer screenshot 2" src="https://github.com/user-attachments/assets/a16b34f8-7af6-438a-b217-f4bb184f3964"></a></td>
    <td><a href="https://github.com/user-attachments/assets/30a93c5e-fde8-43ca-b0f8-b8e782a91c70"><img width="260" alt="iSyncer screenshot 3" src="https://github.com/user-attachments/assets/30a93c5e-fde8-43ca-b0f8-b8e782a91c70"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/6d193883-bd0a-4d85-8bcb-0f818c6a10d9"><img width="260" alt="iSyncer screenshot 4" src="https://github.com/user-attachments/assets/6d193883-bd0a-4d85-8bcb-0f818c6a10d9"></a></td>
    <td><a href="https://github.com/user-attachments/assets/6830ec4f-5182-4f6a-935e-974b1907784b"><img width="260" alt="iSyncer screenshot 5" src="https://github.com/user-attachments/assets/6830ec4f-5182-4f6a-935e-974b1907784b"></a></td>
    <td><a href="https://github.com/user-attachments/assets/33689785-1b29-428b-9acb-4ad9b83e10c5"><img width="260" alt="iSyncer screenshot 6" src="https://github.com/user-attachments/assets/33689785-1b29-428b-9acb-4ad9b83e10c5"></a></td>
  </tr>
  <tr>
    <td><a href="https://github.com/user-attachments/assets/3b94063f-2db0-4f8b-96f5-608d229e8dcd"><img width="260" alt="iSyncer screenshot 7" src="https://github.com/user-attachments/assets/3b94063f-2db0-4f8b-96f5-608d229e8dcd"></a></td>
    <td><a href="https://github.com/user-attachments/assets/c892cc8a-b36d-41f0-8692-653e09274ea1"><img width="260" alt="iSyncer screenshot 8" src="https://github.com/user-attachments/assets/c892cc8a-b36d-41f0-8692-653e09274ea1"></a></td>
<td><a href="https://github.com/user-attachments/assets/68e4dbee-499a-4510-b378-bb8921a3ec8b"><img width="260" alt="iSyncer screenshot 9" src="https://github.com/user-attachments/assets/68e4dbee-499a-4510-b378-bb8921a3ec8b"></a></td>
  </tr>
</table>


# iSyncer

iSyncer is a native macOS media library and USB sync app for the iPod Classic running Apple firmware. It brings back the iTunes-era column browser, brushed-metal controls, and device summary, with playback for music, videos, podcasts, and audiobooks.

[Download the latest release](https://github.com/Meiphia/iSyncer/releases/latest)

## Get started

1. Download the release ZIP, unzip it, and move `iSyncer.app` to Applications. Builds are ad-hoc signed and unnotarized, so macOS may prompt for approval on first launch. The published app is built for Apple silicon and requires macOS 14 or later.
2. Open iSyncer and choose **File → Choose Media Library…**. Select the folder that contains your media. iSyncer caches the library and reads audio tags again when files are new or changed. Use **File → Rescan Media Library** after adding files, or **Relink Moved Library…** if you move the collection.
3. For Ogg/Opus playback, audio tag editing, ReplayGain analysis, or automatic conversion of incompatible videos for iPod, install [FFmpeg](https://ffmpeg.org/download.html). With Homebrew, run `brew install ffmpeg`, then restart iSyncer. Playback and sync of compatible media work with the system frameworks. iSyncer looks in standard Homebrew, MacPorts, and PATH locations.

## Music library and playback

- **Browse and search.** Filter by genre, album artist, and album, switch between cover art and lists, or use Cover Flow. The sidebar artwork can display the current track or the selected track.
- **Play and queue.** Use shuffle, repeat, Party Shuffle, and Up Next. The Mini Player has playback controls, a scrubber, ratings, and a cover that opens the album. Playback supports an equalizer, visualizer, ReplayGain, and optional crossfade. Ogg Vorbis and Opus use a local lossless playback cache.
- **Organize.** Create and reorder playlists, make smart playlists from rules, and browse built-in lists such as Recently Played and My Top Rated. Check or uncheck tracks to control what is eligible for iPod sync.
- **Edit and maintain.** Use **Get Info** for metadata and artwork. Audio tag editing rewrites file metadata in stream-copy mode. **Library Health** surfaces duplicates, inconsistent names, mixed albums, missing tags or artwork, and unreadable files. **Import Inbox** lets you review incoming files before adding them.
- **Read lyrics.** Click **Lyrics** or press **⌘⌥L** to open the pane inside the main window or Mini Player. iSyncer reads embedded lyrics and matching `.lrc` and `.txt` files. Timed lines follow playback and can be clicked to seek. **Find Lyrics** searches [LRCLIB](https://lrclib.net/), prefers synced results that match the track length, falls back to text, and caches matches locally.

## Videos

The scanner walks the selected library recursively. Movies in a `Movies` or `Films` folder can be named `Title (Year)`. For TV, use a folder structure such as `Videos/TV/Scrubs/Season 1/02. My Mentor.mp4` or an episode filename such as `Scrubs.S01E02.My.Mentor.mkv`. MP4 files must be inside a recognized video folder below the library root. Other supported video extensions, including MKV, M4V, MOV, WebM, and AVI, can be found anywhere under the root.

- **Posters** shows movies and TV shows with artwork where available. Open a show for the season picker and episode list. **List** exposes the column browser, checkboxes, and bulk selection.
- **Play** opens videos inside iSyncer with fullscreen, scrubbing, and audio or subtitle selection when the file provides those tracks. **Open in Default Player** is available for files the built-in player cannot decode.
- **Continue Watching** remembers playback positions. Filter to **Unwatched**, mark items manually, or play the next episode when one ends.
- **Get Info** edits titles, release dates, descriptions, and artwork. The TMDB lookup uses your TMDB API read access token and supports individual items, TV seasons, and entire shows, with a review step before saving.

## Podcasts and audiobooks

**Podcasts → Find & Download Podcasts…** searches Apple’s podcast directory or accepts an RSS URL. Download individual MP3 or AAC episodes, or **Follow** a show to download its newest episode and periodically fetch new ones while iSyncer is open. The Podcasts library groups episodes by show and can filter to unplayed episodes.

For local podcasts, use a `Podcasts` folder or the Podcast genre. Audiobooks appear in their own sidebar section when they are M4B files or are identified by their folder or genre. Both sections support resuming playback and have separate iPod sync tabs.

## Sync to an iPod Classic

iSyncer targets USB-mounted iPod Classics running Apple firmware with a writable, uncompressed, signed `iTunesDB` and a readable FireWire GUID. Settings are saved separately for each iPod.

1. Connect your iPod, then select it in **Source**. Grant removable-volume access if macOS asks.
2. In **Music**, choose the entire library or selected playlists, artists, albums, and genres. Selected music can fill remaining space with complete albums and reserve free space for future media.
3. Use **Movies**, **TV Shows**, **Podcasts**, and **Audiobooks** to choose what to send. TV can sync individual episodes or seasons, or keep the next *N* unwatched episodes of a show. Podcasts can sync checked, latest, or unplayed episodes. Pin episodes you want to keep. TV retention can use watch history from the Mac and iPod.
4. Click **Preview Sync**, review additions, replacements, metadata changes, skips, and removals, then click **Apply**. Some music and episode selection rules remove previously managed copies from the iPod. View the exact changes before applying.
5. Click **Eject** when the transfer finishes.

The sync engine matches existing tracks to avoid copying them again when possible. It syncs cover artwork and can use Album Artist as Artist in the iPod database so featured artists stay grouped. Common compatible audio includes MP3, AAC-LC, 16-bit ALAC, and 16-bit PCM WAV/AIFF, up to 48 kHz and two channels. Compatible H.264 Baseline video with AAC can be copied directly. With FFmpeg installed, iSyncer converts incompatible selected videos during preview and caches the compatible copies on the Mac.

**Stop Sync & Save** commits completed transfers. **Last Results** explains what happened and can preview a retry of eligible failed items. **On This iPod** lists device contents and lets you recover selected media to the Mac or review video removals. **Summary** includes play-count import, ratings and listening-progress comparison, and database backups. Backups cover the device index. The restore preview checks that its referenced media files are still available.

## Last.fm, Discord, and service settings

| Feature | Setup and data sent |
| --- | --- |
| Last.fm | In **Settings → Last.fm**, enter your own API key and shared secret, then connect your account. Choose whether to scrobble Mac playback, imported timestamped iPod plays, or both. Failed sends queue locally. |
| Discord Rich Presence | In **Settings → Discord**, enter a Discord application ID and enable the media types to share. Presence uses the Discord desktop app and includes song and artist information. iSyncer searches Apple Music and MusicBrainz for public album art. |
| Discord artwork fallback | **Share artwork from my music files** is opt-in. When catalogs find no match, iSyncer sends a small JPEG to its HTTPS relay. The URL is unlisted and expires after five minutes. Advanced settings support a [custom relay](Support/DiscordArtworkRelay/README.md). |
| Lyrics, podcasts, and video metadata | Online lookups send the corresponding search terms or media tags to LRCLIB, Apple’s podcast directory, or TMDB. RSS subscriptions fetch feeds and selected media from their publishers. |

The local library index and iPod database backups are stored under `~/Library/Application Support/iSyncer`. Service credentials are stored in the macOS Keychain.

## Build from source

Use macOS 14 or later with a Swift 6 toolchain. The package uses system frameworks.

```sh
swift test
./build.sh
open build/iSyncer.app
```

For the optional iPod round-trip test, set `ISYNCER_TEST_IPOD` to a compatible iPod mount and `ISYNCER_TEST_MUSIC` to a folder of compatible tagged music. The test reads the original device data and applies writes to a temporary copy. The regular suite also includes synthetic device tests.

| Project path | Contents |
| --- | --- |
| `Sources/iSyncer` | SwiftUI and AppKit interface, playback, media indexing, and integrations |
| `Sources/ClassicSync` | Device inspection, iTunes database handling, artwork, transfer planning, and backup restore |
| `Tests/ClassicSyncTests` | Parser, library cache, and device sync tests |
| `Resources` | App icons, credits artwork, and bundle metadata |
| `Support/DiscordArtworkRelay` | Self-hosted relay and hosted Worker source |

The Classic database layout and signing work draws on the documentation and implementations in [libgpod](https://github.com/gtkpod/libgpod). Video metadata uses [TMDB](https://www.themoviedb.org/) and is not endorsed or certified by TMDB. iSyncer is an independent project and is not affiliated with Apple.
