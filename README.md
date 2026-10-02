# Captionate

Native macOS app that captions your videos — fully on-device, free, no uploads, no ffmpeg.

**Flow:** drop a video → *Generate Captions* (Apple Speech, on-device) → edit text/timings → style → export a captioned `.mp4` or `.srt` / `.vtt`.

## Features
- On-device transcription via Apple's Speech framework (English-India, Hindi and 50+ languages)
- Editable caption list — fix words, nudge timings, add/delete, click to seek
- Live preview that matches the export exactly
- Styles: any installed font, bold, UPPERCASE, size, colour, shadow, background box, position, margin, width
- **Word-by-word highlight** (karaoke style) for Shorts/Reels
- Presets: Classic, Shorts/Reels, Minimal
- Burn-in export with AVFoundation + Core Animation (hardware-encoded MP4, keeps original audio and rotation)
- SRT / WebVTT export and import

## Install (build the DMG)
Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open build/Captionate.dmg     # drag Captionate into Applications
```

For an Intel + Apple Silicon universal build (needs full Xcode): `UNIVERSAL=1 ./build.sh`

Or push this folder to GitHub — `.github/workflows/build.yml` builds the DMG on a macOS runner and uploads it as an artifact (and to the release when you push a `v*` tag).

### First launch
The app is ad-hoc signed, not notarized. If macOS says it can't be opened:
right-click **Captionate.app → Open → Open**, or run
`xattr -dr com.apple.quarantine /Applications/Captionate.app`.

On first transcription macOS asks for Speech Recognition permission — allow it.
If a language says it's unavailable on-device, add it in **System Settings → Keyboard → Dictation → Languages**.

## Project layout
```
Sources/Captionate/
  CaptionateApp.swift   app entry, menus
  AppState.swift        state, load/transcribe/export actions, presets
  Transcriber.swift     audio chunking + SFSpeechRecognizer (on-device)
  CaptionBuilder.swift  words → captions, SRT/VTT read/write
  VideoExporter.swift   burn-in renderer (CATextLayer timeline)
  Views.swift           SwiftUI UI: player, overlay, list, style panel
  Models.swift          Word, CaptionSegment, CaptionStyle
Resources/              Info.plist, AppIcon.icns
build.sh                builds .app + .dmg
```

## Notes
- Audio is transcribed in 50-second chunks; a word right at a chunk boundary can occasionally be split.
- Hinglish works best with **English (India)**; pure Hindi with **Hindi (India)**.
- Editing a caption's text keeps word timings if the word count is unchanged; otherwise highlight timing is spread evenly across the caption.
