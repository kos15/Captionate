import Foundation
import AVFoundation
import AppKit
import QuartzCore
import CoreText

enum VideoExportError: LocalizedError {
    case noVideoTrack
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .sessionFailed(let m): return "Video export failed: \(m)"
        }
    }
}

/// Burns captions into the video using AVFoundation + Core Animation.
/// No ffmpeg needed — this is Apple's native render pipeline (hardware encoded).
enum VideoExporter {
    static func export(videoURL: URL,
                       segments: [CaptionSegment],
                       style: CaptionStyle,
                       edit: EditOptions,
                       to outURL: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoExportError.noVideoTrack
        }
        let naturalSize = try await srcVideo.load(.naturalSize)
        let transform = try await srcVideo.load(.preferredTransform)
        let fps = try await srcVideo.load(.nominalFrameRate)
        let videoRange = try await srcVideo.load(.timeRange)
        let duration = try await asset.load(.duration).seconds

        // Smart cuts (silences / filler words) and captions re-timed to match.
        let plan = EditPlan.make(segments: segments, duration: duration, options: edit)
        let captions = plan.apply(to: segments, dropFillers: edit.removeFillers)

        // Audio sources: a cleaned copy of the first track, or the original tracks.
        // `range` is in source-video time; source time - `offset` = time within `track`.
        var audioSources: [(track: AVAssetTrack, range: CMTimeRange, offset: CMTime)] = []
        var cleanedURL: URL?
        defer { if let cleanedURL { try? FileManager.default.removeItem(at: cleanedURL) } }
        let originalAudio = try await asset.loadTracks(withMediaType: .audio)
        var progressBase = 0.0
        if edit.cleanAudio || edit.normalizeLoudness, let first = originalAudio.first,
           let url = try await AudioCleaner.process(videoURL, denoise: edit.cleanAudio,
                                                    normalize: edit.normalizeLoudness) {
            cleanedURL = url
            progressBase = 0.15
            progress(progressBase)
            let cleaned = AVURLAsset(url: url)
            if let track = try await cleaned.loadTracks(withMediaType: .audio).first {
                let origStart = try await first.load(.timeRange).start
                let range = try await track.load(.timeRange)
                audioSources.append((track, CMTimeRange(start: range.start + origStart, duration: range.duration), origStart))
            }
        }
        if audioSources.isEmpty {
            for track in originalAudio {
                let range = try await track.load(.timeRange)
                audioSources.append((track, range, CMTime.zero))
            }
        }

        // Composition: the kept pieces, back to back.
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoExportError.sessionFailed("couldn't create video track")
        }
        let compAudio = audioSources.map { _ in
            comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var cursor = CMTime.zero
        for r in plan.kept {
            let piece = CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: r.upperBound, preferredTimescale: 600))
            let v = piece.intersection(videoRange)
            if !v.isEmpty { try compVideo.insertTimeRange(v, of: srcVideo, at: cursor + (v.start - piece.start)) }
            for (src, dst) in zip(audioSources, compAudio) {
                let a = piece.intersection(src.range)
                guard let dst, !a.isEmpty else { continue }
                try dst.insertTimeRange(CMTimeRange(start: a.start - src.offset, duration: a.duration),
                                        of: src.track, at: cursor + (a.start - piece.start))
            }
            cursor = cursor + piece.duration
        }
        let total = comp.duration

        // Background music, looped to length, with a fade-out.
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        if let musicURL = edit.musicURL {
            let music = AVURLAsset(url: musicURL)
            if let track = try await music.loadTracks(withMediaType: .audio).first,
               let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await track.load(.timeRange)
                var at = CMTime.zero
                while at < total && range.duration.seconds > 0.5 {
                    let length = min(range.duration, total - at)
                    try dst.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: track, at: at)
                    at = at + length
                }
                let params = AVMutableAudioMixInputParameters(track: dst)
                let volume = Float(edit.musicVolume)
                params.setVolume(volume, at: .zero)
                let fade = CMTime(seconds: min(2, total.seconds / 4), preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: total - fade, duration: fade))
                mixParameters.append(params)
            }
        }

        // Output canvas: aspect ratio + resolution, video filled (cropped) or fitted inside.
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let source = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let renderSize = canvasSize(source: source, edit: edit)
        let scale = edit.fit == .fill
            ? max(renderSize.width / source.width, renderSize.height / source.height)
            : min(renderSize.width / source.width, renderSize.height / source.height)
        let base = transform
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (renderSize.width - source.width * scale) / 2,
                                             y: (renderSize.height - source.height * scale) / 2))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let timescale = CMTimeScale(fps > 0 ? max(1, fps.rounded()) : 30)
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.backgroundColor = edit.canvasColor.cgColorValue
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(base, at: .zero)
        if edit.autoZoom { addZooms(to: layerInstruction, base: base, canvas: renderSize, captions: captions) }
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Core Animation overlay. macOS layers have a bottom-left origin.
        let frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = frame
        let videoLayer = CALayer()
        videoLayer.frame = frame
        parent.addSublayer(videoLayer)
        for layer in CaptionLayers.make(segments: captions, style: style, renderSize: renderSize) {
            parent.addSublayer(layer)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoExportError.sessionFailed("export session unavailable")
        }
        try? FileManager.default.removeItem(at: outURL)
        session.videoComposition = videoComposition
        if !mixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            session.audioMix = mix
        }
        session.outputURL = outURL
        session.outputFileType = outURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = true

        let ticker = Task {
            while !Task.isCancelled {
                progress(progressBase + (1 - progressBase) * Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        ticker.cancel()

        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw CancellationError()
        default:
            throw VideoExportError.sessionFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    /// Output size for the chosen aspect ratio and resolution (even dimensions for the encoder).
    static func canvasSize(source: CGSize, edit: EditOptions) -> CGSize {
        let ratio = edit.aspect.ratio ?? source.width / max(source.height, 1)
        let short = edit.resolution.shortSide ?? min(source.width, source.height)
        let size = ratio >= 1 ? CGSize(width: short * ratio, height: short)
                              : CGSize(width: short, height: short / ratio)
        return CGSize(width: evenRound(size.width), height: evenRound(size.height))
    }

    /// Gentle punch-in zooms on every other caption, like an editor's jump-zooms.
    private static func addZooms(to layer: AVMutableVideoCompositionLayerInstruction, base: CGAffineTransform,
                                 canvas: CGSize, captions: [CaptionSegment]) {
        let cx = canvas.width / 2, cy = canvas.height / 2
        let zoom = base
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: 1.12, y: 1.12))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
        var last = 0.0
        for (i, caption) in captions.enumerated() where i % 2 == 1 {
            let a = max(caption.start, last), b = caption.end
            guard b - a > 0.8 else { continue }
            layer.setTransformRamp(fromStart: base, toEnd: zoom, timeRange: CMTimeRange(start: time(a), end: time(a + 0.25)))
            layer.setTransformRamp(fromStart: zoom, toEnd: base, timeRange: CMTimeRange(start: time(b - 0.25), end: time(b)))
            last = b
        }
    }

    private static func evenRound(_ v: CGFloat) -> CGFloat {
        let r = Int(v.rounded())
        return CGFloat(r % 2 == 0 ? r : r + 1)
    }
}

/// Builds caption layers. Used by both the export and the live preview, so they match exactly.
///
/// Each caption is a box layer holding one bitmap layer per word, drawn with Core Text (bitmaps render
/// reliably in AVVideoCompositionCoreAnimationTool; CATextLayer does not). Highlights and animations are
/// Core Animation timings in video seconds — the export plays them, the preview freezes them at the playhead.
enum CaptionLayers {
    static func make(segments: [CaptionSegment], style: CaptionStyle, renderSize: CGSize) -> [CALayer] {
        var layers = segments.compactMap { $0.end > $0.start ? segmentLayer($0, style: style, renderSize: renderSize) : nil }
        if let hook = hookLayer(style: style, renderSize: renderSize) { layers.append(hook) }
        return layers
    }

    /// The hook title: a bold headline banner at the top for the first few seconds.
    static func hookLayer(style: CaptionStyle, renderSize: CGSize) -> CALayer? {
        let text = style.hookText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, style.hookDuration > 0 else { return nil }
        var s = style
        s.position = .top
        s.verticalMargin = 0.07
        s.showBackground = true
        s.backgroundColor = style.hookColor
        s.backgroundOpacity = 1
        s.textColor = .white
        s.fontScale = style.fontScale * 0.9
        s.maxWidth = 0.8
        s.wordHighlight = false
        s.wordBackground = false
        s.autoEmphasis = false
        s.autoEmoji = false
        s.wordArt = .none
        s.effect = .pop
        return segmentLayer(CaptionSegment(start: 0, end: style.hookDuration, text: text), style: s, renderSize: renderSize)
    }

    /// The word as drawn: censored, cased, with an emoji when enabled.
    private static func displayWord(_ word: String, style: CaptionStyle) -> String {
        var s = style.displayText(style.censorProfanity ? TextTools.censor(word) : word)
        if style.autoEmoji, let emoji = TextTools.emoji(for: word) { s += " " + emoji }
        return s
    }

    private struct Placement {
        var x, baseline, width: CGFloat
    }

    static func segmentLayer(_ seg: CaptionSegment, style: CaptionStyle, renderSize: CGSize) -> CALayer? {
        let tokens = seg.timedWords()
        guard !tokens.isEmpty, renderSize.width > 0, renderSize.height > 0 else { return nil }
        let fontSize = CGFloat(style.fontScale) * renderSize.height
        let font = style.nsFont(size: fontSize) as CTFont
        let emphasisFont = style.nsFont(size: fontSize * CGFloat(style.emphasisScale)) as CTFont
        let attrs = textAttributes(font)

        // "Big & small": one hero word, large in its own font on its own line; the rest smaller.
        let hero = style.heroWord ? TextTools.heroIndex(tokens, overrides: seg.overrides) : nil
        let heroAttrs = textAttributes(style.heroFont(size: fontSize * CGFloat(style.heroScale)) as CTFont)
        let smallAttrs = textAttributes(style.nsFont(size: fontSize * CGFloat(style.smallScale)) as CTFont)
        let smallEmphasisAttrs = textAttributes(
            style.nsFont(size: fontSize * CGFloat(style.smallScale * style.emphasisScale)) as CTFont)

        // Per-word text, font and colour (word editor overrides win over automatic emphasis).
        var words: [String] = [], wordAttrs: [[NSAttributedString.Key: Any]] = [], fills: [CGColor] = []
        for (i, token) in tokens.enumerated() {
            let override = seg.overrides[i]
            words.append(displayWord(token.text, style: style))
            if let hero {
                if i == hero {
                    wordAttrs.append(heroAttrs)
                    fills.append((override?.color ?? style.heroColor).cgColorValue)
                    continue
                }
                let emphasized = override?.emphasis ?? false
                wordAttrs.append(emphasized ? smallEmphasisAttrs : smallAttrs)
                fills.append((override?.color ?? (emphasized ? style.emphasisColor : style.textColor)).cgColorValue)
                continue
            }
            let emphasized = override?.emphasis ?? (style.autoEmphasis && TextTools.isKeyword(token.text))
            wordAttrs.append(emphasized ? textAttributes(emphasisFont) : attrs)
            fills.append((override?.color ?? (emphasized ? style.emphasisColor : style.textColor)).cgColorValue)
        }

        // Lay out the whole caption once to find where each word sits.
        let full = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (i, w) in words.enumerated() {
            if i > 0 {
                let breaksLine = hero.map { i == $0 || i == $0 + 1 } ?? false
                full.append(NSAttributedString(string: breaksLine ? "\n" : " ", attributes: hero == nil ? attrs : smallAttrs))
            }
            let word = NSAttributedString(string: w, attributes: wordAttrs[i])
            ranges.append(NSRange(location: full.length, length: word.length))
            full.append(word)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(full as CFAttributedString)
        let maxTextWidth = renderSize.width * CGFloat(style.maxWidth)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        let padX = fontSize * 0.35, padY = fontSize * 0.2
        let boxSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        let margin = renderSize.height * CGFloat(style.verticalMargin)
        let y: CGFloat
        switch style.position {
        case .bottom: y = margin
        case .middle: y = (renderSize.height - boxSize.height) / 2
        case .top: y = renderSize.height - margin - boxSize.height
        }

        let container = CALayer()
        container.frame = CGRect(x: (renderSize.width - boxSize.width) / 2, y: y,
                                 width: boxSize.width, height: boxSize.height)
        show(container, from: seg.start, to: seg.end)

        let content = CALayer()
        content.frame = container.bounds
        container.addSublayer(content)
        addEntrance(style.effect, to: content, start: seg.start, duration: seg.end - seg.start, fontSize: fontSize)

        if style.showBackground {
            let bg = CALayer()
            bg.frame = content.bounds
            bg.backgroundColor = style.backgroundColor.cgColorValue.copy(alpha: style.backgroundOpacity)
            bg.cornerRadius = fontSize * 0.25
            content.addSublayer(bg)
        }
        let boxes = CALayer(), texts = CALayer()
        boxes.frame = content.bounds
        texts.frame = content.bounds
        content.addSublayer(boxes)
        content.addSublayer(texts)

        let bleed = ceil(fontSize * 0.45)   // room for shadow, outline, glow and 3D depth
        for (i, range) in ranges.enumerated() {
            guard let p = place(range, lines: lines, origins: origins) else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: words[i], attributes: wordAttrs[i]))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let wordRect = CGRect(x: padX + p.x, y: padY + p.baseline - descent,
                                  width: p.width, height: ascent + descent)
            let start = i == 0 ? seg.start : max(seg.start, tokens[i].start)
            let end = i == tokens.count - 1 ? seg.end : min(seg.end, tokens[i + 1].start)

            if style.wordBackground && end > start {
                let box = CALayer()
                box.frame = wordRect.insetBy(dx: -fontSize * 0.14, dy: -fontSize * 0.06)
                box.backgroundColor = style.wordBackgroundColor.cgColorValue
                box.cornerRadius = fontSize * 0.18
                show(box, from: start, to: end)
                boxes.addSublayer(box)
            }

            let group = CALayer()
            group.frame = wordRect.insetBy(dx: -bleed, dy: -bleed)
            let origin = CGPoint(x: bleed, y: bleed + descent)

            let normal = CALayer()
            normal.frame = group.bounds
            normal.contents = wordImage(line, size: group.bounds.size, origin: origin,
                                        fill: fills[i], gradient: true, style: style, fontSize: fontSize)
            group.addSublayer(normal)

            if style.wordHighlight && end > start {
                let hi = CALayer()
                hi.frame = group.bounds
                hi.contents = wordImage(line, size: group.bounds.size, origin: origin,
                                        fill: style.highlightColor.cgColorValue,
                                        gradient: false, style: style, fontSize: fontSize)
                show(hi, from: start, to: end)
                group.addSublayer(hi)
            }

            addWordAnimation(style.effect, to: group, start: start, end: end, line: line,
                             length: (words[i] as NSString).length, bleed: bleed)
            texts.addSublayer(group)
        }
        return container
    }

    // MARK: Text

    private static func textAttributes(_ font: CTFont) -> [NSAttributedString.Key: Any] {
        var alignment = CTTextAlignment.center
        let para = withUnsafeBytes(of: &alignment) { buf in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: buf.count, value: buf.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        // Colour comes from the drawing context, so one line can be painted in any colour.
        return [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para]
    }

    /// Where a word sits in the laid-out caption (frame coordinates, bottom-left origin).
    private static func place(_ range: NSRange, lines: [CTLine], origins: [CGPoint]) -> Placement? {
        for (line, origin) in zip(lines, origins) {
            let lr = CTLineGetStringRange(line)
            guard range.location >= lr.location, range.location < lr.location + lr.length else { continue }
            let end = min(range.location + range.length, lr.location + lr.length)
            let x0 = CTLineGetOffsetForStringIndex(line, range.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, end, nil)
            return Placement(x: origin.x + x0, baseline: origin.y, width: x1 - x0)
        }
        return nil
    }

    /// One word drawn with its word-art treatment into a 2x bitmap.
    /// `gradient` allows gradient/prism fills (off for the highlight copy, which is a solid colour).
    private static func wordImage(_ line: CTLine, size: CGSize, origin: CGPoint, fill: CGColor,
                                  gradient: Bool, style: CaptionStyle, fontSize: CGFloat) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil,
                                  width: max(1, Int(ceil(size.width * scale))),
                                  height: max(1, Int(ceil(size.height * scale))),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity
        ctx.setLineJoin(.round)
        func draw(at p: CGPoint, _ mode: CGTextDrawingMode) {
            ctx.setTextDrawingMode(mode)
            ctx.textPosition = p
            CTLineDraw(line, ctx)
        }
        let art = style.wordArt
        let effect = style.artColor.cgColorValue
        let depth = style.artDepthColor.cgColorValue

        // Bubble: a pill behind the word.
        if art == .bubble {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let pill = CGRect(x: origin.x - fontSize * 0.16, y: origin.y - descent - fontSize * 0.06,
                              width: width + fontSize * 0.32, height: ascent + descent + fontSize * 0.12)
            let radius = min(pill.height, pill.width) / 2
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(effect)
            ctx.fillPath()
        }

        // Glitch: offset red and cyan copies behind the word.
        if art == .glitch {
            let shift = fontSize * 0.04
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.35, alpha: 0.9))
            draw(at: CGPoint(x: origin.x - shift, y: origin.y + shift * 0.4), .fill)
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.9, blue: 1, alpha: 0.9))
            draw(at: CGPoint(x: origin.x + shift, y: origin.y - shift * 0.4), .fill)
        }

        // 3D: stacked copies stepping down-right.
        if art == .extrude || art == .comic {
            let steps = 6, step = fontSize * 0.014
            ctx.setFillColor(depth)
            ctx.setStrokeColor(depth)
            ctx.setLineWidth(fontSize * 0.16)
            for k in stride(from: steps, through: 1, by: -1) {
                draw(at: CGPoint(x: origin.x + CGFloat(k) * step, y: origin.y - CGFloat(k) * step),
                     art == .comic ? .fillStroke : .fill)
            }
        }
        if art == .outline || art == .comic {
            ctx.setStrokeColor(art == .comic ? depth : effect)
            ctx.setLineWidth(fontSize * (art == .comic ? 0.16 : 0.12))
            draw(at: origin, .stroke)
        }

        ctx.saveGState()
        if art == .neon {
            ctx.setFillColor(fill)
            ctx.setShadow(offset: .zero, blur: fontSize * 0.6, color: effect)
            draw(at: origin, .fill)
            ctx.setShadow(offset: .zero, blur: fontSize * 0.25, color: effect)
        } else if art == .glow {
            ctx.setFillColor(fill)
            ctx.setShadow(offset: .zero, blur: fontSize * 0.9, color: fill)
            draw(at: origin, .fill)
            ctx.setShadow(offset: .zero, blur: fontSize * 0.4, color: fill)
        } else if style.showShadow && art != .extrude && art != .comic && art != .bubble {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.16,
                          color: CGColor(gray: 0, alpha: 0.85))
        }
        ctx.setFillColor(fill)
        draw(at: origin, .fill)
        ctx.restoreGState()

        if gradient && (art == .gradient || art == .prism) {
            // Gradient: text colour → effect colour, top to bottom. Prism: a rainbow across the word.
            ctx.saveGState()
            draw(at: origin, .clip)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if art == .gradient,
               let g = CGGradient(colorsSpace: space, colors: [fill, effect] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
            } else if art == .prism {
                let rainbow = [CGColor(srgbRed: 1, green: 0.25, blue: 0.3, alpha: 1),
                               CGColor(srgbRed: 1, green: 0.65, blue: 0.1, alpha: 1),
                               CGColor(srgbRed: 1, green: 0.95, blue: 0.2, alpha: 1),
                               CGColor(srgbRed: 0.3, green: 0.95, blue: 0.4, alpha: 1),
                               CGColor(srgbRed: 0.2, green: 0.75, blue: 1, alpha: 1),
                               CGColor(srgbRed: 0.65, green: 0.4, blue: 1, alpha: 1)]
                if let g = CGGradient(colorsSpace: space, colors: rainbow as CFArray, locations: nil) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: origin.x, y: 0),
                                           end: CGPoint(x: size.width - origin.x, y: 0), options: [])
                }
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // MARK: Timing & animation

    private static func at(_ t: Double) -> CFTimeInterval { t <= 0 ? AVCoreAnimationBeginTimeAtZero : t }

    /// Hidden except during [start, end).
    private static func show(_ layer: CALayer, from start: Double, to end: Double) {
        layer.opacity = 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 1
        a.beginTime = at(start)
        a.duration = max(0.001, end - start)
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "visibility")
    }

    /// An animation that starts at `start` and holds its first value before that (fillMode backwards).
    private static func keyframes(_ keyPath: String, _ values: [CGFloat], start: Double, duration: Double,
                                  discrete: Bool = false) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        if discrete { a.calculationMode = .discrete }
        a.beginTime = at(start)
        a.duration = duration
        a.fillMode = .backwards
        a.isRemovedOnCompletion = false
        return a
    }

    /// Caption-level entrances.
    private static func addEntrance(_ animation: CaptionAnimation, to layer: CALayer,
                                    start: Double, duration: Double, fontSize: CGFloat) {
        let d = min(0.25, duration * 0.5)
        guard d > 0 else { return }
        switch animation {
        case .fade:
            layer.add(keyframes("opacity", [0, 1], start: start, duration: d), forKey: "in")
        case .pop:
            layer.add(keyframes("transform.scale", [0.5, 1.12, 1], start: start, duration: d), forKey: "in")
        case .slideUp:
            layer.add(keyframes("transform.translation.y", [-fontSize * 0.8, 0], start: start, duration: d), forKey: "in")
            layer.add(keyframes("opacity", [0, 1], start: start, duration: d), forKey: "fade")
        default:
            break
        }
    }

    /// Word-level reveals and emphasis.
    private static func addWordAnimation(_ animation: CaptionAnimation, to group: CALayer,
                                         start: Double, end: Double, line: CTLine, length: Int, bleed: CGFloat) {
        switch animation {
        case .wordByWord, .popWords:
            group.add(keyframes("opacity", [0, 1], start: start, duration: 0.12), forKey: "appear")
            if animation == .popWords {
                group.add(keyframes("transform.scale", [0.3, 1.15, 1], start: start, duration: 0.2), forKey: "pop")
            }
        case .typewriter:
            // A mask that widens one character at a time while the word is spoken.
            var widths: [CGFloat] = [0]
            for k in stride(from: 1, to: length, by: 1) {
                widths.append(bleed + CTLineGetOffsetForStringIndex(line, k, nil))
            }
            widths.append(group.bounds.width)
            let mask = CALayer()
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            mask.anchorPoint = CGPoint(x: 0, y: 0.5)
            mask.frame = group.bounds
            let typing = max(0.05, min(end - start, Double(length) * 0.06))
            let a = keyframes("bounds.size.width", widths, start: start, duration: typing, discrete: true)
            a.fillMode = .both
            mask.add(a, forKey: "type")
            group.mask = mask
        case .bounce:
            let d = end - start
            guard d > 0.05 else { return }
            let ramp = min(0.12, d / 2) / d
            let a = keyframes("transform.scale", [1, 1.18, 1.18, 1], start: start, duration: d)
            a.keyTimes = [0, NSNumber(value: ramp), NSNumber(value: 1 - ramp), 1]
            a.fillMode = .removed
            group.add(a, forKey: "bounce")
        default:
            break
        }
    }
}
