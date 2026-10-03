# Captionate

Native macOS app that captions your videos — fully on-device, free, no uploads, no ffmpeg.

**Flow:** drop a video → *Generate Captions* (Apple Speech, on-device) → edit text/timings → style → export a captioned `.mp4` or `.srt` / `.vtt`.

## Features
Everything runs on your Mac — no uploads, no account, no watermark.

The sidebar is grouped by task:

| Panel | What's in it |
|---|---|
| **Captions** | Editable caption list, click to seek, find & replace, merge/split captions, **word editor** (fix a word, retime it, recolour it, emphasise it) |
| **Styles** | 37 ready-made looks — Hormozi, MrBeast, Word Pop, Big & Small, Editorial, Karaoke, Highlighted, Neon, Deep Glow, Glitch, Prism, Fire, Comic, Retro 3D, Bubble, Y2K, Cinematic, Podcast, News… |
| **Text** | Any installed font, size, colour, shadow, UPPERCASE, caption box, **Big & small** (one big word per caption in its own font, the rest small), keyword emphasis, auto emoji, swear-word censoring |
| **Effects** | Animations (fade, pop, slide up, typewriter, word by word, pop each word, bounce), word art (outline, gradient, neon, deep glow, glitch, prism, bubble, 3D, comic), spoken-word colour and word box |
| **Layout** | Position, margin, width, **9:16 / 16:9 / 1:1 / 4:5** output (crop or fit), 720p–**4K**, hook title banner, caption length |
| **Edit & Audio** | Remove silences and filler words (captions re-timed), auto zoom punch-ins, voice clean-up (hum & background noise), loudness levelling, background music |
| **Language** | Transliterate between Roman, Devanagari and 11 more scripts (Hinglish ↔ हिन्दी), translate captions into 20 languages (on-device, macOS 15+), restore the original |

Also: on-device transcription with Apple's Speech framework (English-India, Hindi and 50+ languages), live preview that matches the export exactly, hardware-encoded MP4, SRT / WebVTT import and export.

Not included: cloud generative-AI features (AI avatars, eye-contact correction, generated B-roll or music, prompt-based editing) — they need server-side models, and Captionate never uploads your video.

## Install (build the DMG)
Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open build/Captionate.dmg     # drag Captionate into Applications
```

For an Intel + Apple Silicon universal build (needs full Xcode): `UNIVERSAL=1 ./build.sh`

The DMG carries the Captionate icon (on the mounted disk and on the `.dmg` file) and opens to a
drag-to-Applications window with a patterned background. Pick a background with `DMG_BACKGROUND`:

```bash
./build.sh                                   # default: dots
DMG_BACKGROUND=grid ./build.sh               # built-in: dots | grid | diagonal | waves
DMG_BACKGROUND=~/Pictures/my-bg.png ./build.sh   # your own image (scaled to 660×400)
```

The window layout is applied through Finder — if macOS asks, allow Terminal to control Finder.
To edit the built-in patterns, change and run `Resources/dmg/make_backgrounds.py` (needs Pillow).

Or let GitHub do it — `.github/workflows/build.yml` builds the DMG on a macOS runner on every push to `main` that touches the app, uploads it as an artifact, and commits the fresh `build/Captionate.dmg` (the file the website's Download button serves). Run it by hand from the Actions tab to choose a background.

### First launch ("Apple could not verify Captionate…")
Builds without a Developer ID are ad-hoc signed and not notarized, so Gatekeeper shows
*"Apple could not verify "Captionate" is free of malware…"*. The app is safe — the source is right here. To open it:

- **macOS 15 Sequoia and later:** double-click Captionate, click **Done**, then open
  **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Captionate, and confirm.
- **macOS 14 Sonoma:** right-click **Captionate.app → Open → Open**.
- **Any version (Terminal):** `xattr -dr com.apple.quarantine /Applications/Captionate.app`

You only need to do this once.

### Removing the warning for everyone (signing + notarization)
Gatekeeper only trusts apps signed with an Apple **Developer ID** and notarized by Apple — this
needs an [Apple Developer Program](https://developer.apple.com/programs/) membership.
`build.sh` does the rest automatically:

```bash
xcrun notarytool store-credentials captionate --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=captionate ./build.sh
```

For the GitHub workflow, add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | `base64 -i DeveloperID.p12` — your exported *Developer ID Application* certificate |
| `MACOS_CERTIFICATE_PASSWORD` | the .p12 export password |
| `SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | your 10-character Team ID |
| `APPLE_APP_PASSWORD` | an app-specific password from appleid.apple.com |

With those set, every CI build is signed, notarized and stapled, and opens with no warning.

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
  Views.swift           SwiftUI UI: player, preview overlay, caption list
  Panels.swift          sidebar panels (styles, text, effects, layout, edit, language), word editor
  StylePresets.swift    the style library
  EditPlan.swift        silence / filler-word cuts and caption re-timing
  AudioCleaner.swift    voice clean-up and loudness levelling
  TextTools.swift       keywords, emoji, censoring, script conversion
  Translation.swift     on-device caption translation (macOS 15+)
  Models.swift          Word, CaptionSegment, CaptionStyle, EditOptions
Resources/              Info.plist, AppIcon.icns, dmg/ (DMG backgrounds)
build.sh                builds .app + .dmg
```

## Notes
- Audio is transcribed in 50-second chunks; a word right at a chunk boundary can occasionally be split.
- Hinglish works best with **English (India)**; pure Hindi with **Hindi (India)**.
- Editing a caption's text keeps word timings if the word count is unchanged; otherwise highlight timing is spread evenly across the caption.
