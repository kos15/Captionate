import Foundation
import AVFoundation
import AppKit
import QuartzCore

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

        // Composition: original video + all audio tracks.
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoExportError.sessionFailed("couldn't create video track")
        }
        try compVideo.insertTimeRange(videoRange, of: srcVideo, at: videoRange.start)
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            let range = try await audio.load(.timeRange)
            if let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(range, of: audio, at: range.start)
            }
        }

        // Render size honours rotation (e.g. portrait iPhone footage).
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: evenRound(abs(rotated.width)), height: evenRound(abs(rotated.height)))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let timescale = CMTimeScale(fps > 0 ? max(1, fps.rounded()) : 30)
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Core Animation overlay. macOS layers have a bottom-left origin.
        let frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = frame
        let videoLayer = CALayer()
        videoLayer.frame = frame
        parent.addSublayer(videoLayer)
        for layer in CaptionLayers.make(segments: segments, style: style, renderSize: renderSize) {
            parent.addSublayer(layer)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoExportError.sessionFailed("export session unavailable")
        }
        try? FileManager.default.removeItem(at: outURL)
        session.videoComposition = videoComposition
        session.outputURL = outURL
        session.outputFileType = outURL.pathExtension.lowercased() == "mov" ? .mov : .mp4
        session.shouldOptimizeForNetworkUse = true

        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
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

    private static func evenRound(_ v: CGFloat) -> CGFloat {
        let r = Int(v.rounded())
        return CGFloat(r % 2 == 0 ? r : r + 1)
    }
}

/// Builds caption layers. Used by both the export and the live preview, so they match exactly.
enum CaptionLayers {
    /// Timed layers for the whole video (export).
    static func make(segments: [CaptionSegment], style: CaptionStyle, renderSize: CGSize) -> [CALayer] {
        let fontSize = CGFloat(style.fontScale) * renderSize.height
        var layers: [CALayer] = []

        for seg in segments where seg.end > seg.start {
            let tokens = seg.timedWords()
            if style.tracksActiveWord && !tokens.isEmpty {
                // One layer per active word: the full line with that word highlighted.
                for (i, w) in tokens.enumerated() {
                    let start = i == 0 ? seg.start : w.start
                    let end = i == tokens.count - 1 ? seg.end : tokens[i + 1].start
                    guard end > start else { continue }
                    let layer = caption(tokens.map(\.text), highlight: i, style: style,
                                        fontSize: fontSize, renderSize: renderSize)
                    layers.append(timed(layer, start: start, end: end))
                }
            } else {
                let words = seg.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let layer = caption(words, highlight: nil, style: style, fontSize: fontSize, renderSize: renderSize)
                layers.append(timed(layer, start: seg.start, end: seg.end))
            }
        }
        return layers
    }

    /// The caption as it looks at `time` (live preview).
    static func still(segment: CaptionSegment, time: Double, style: CaptionStyle, renderSize: CGSize) -> CALayer {
        let fontSize = CGFloat(style.fontScale) * renderSize.height
        let tokens = segment.timedWords()
        if style.tracksActiveWord && !tokens.isEmpty {
            let active = tokens.lastIndex { $0.start <= time } ?? 0
            return caption(tokens.map(\.text), highlight: active, style: style,
                           fontSize: fontSize, renderSize: renderSize)
        }
        let words = segment.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return caption(words, highlight: nil, style: style, fontSize: fontSize, renderSize: renderSize)
    }

    /// Returns the caption text and the character range of the highlighted word.
    static func attributed(_ words: [String], highlight: Int?, style: CaptionStyle,
                           fontSize: CGFloat) -> (text: NSAttributedString, highlightRange: NSRange?) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let font = style.nsFont(size: fontSize)
        let normal = NSColor(style.textColor)
        let hi = style.wordHighlight ? NSColor(style.highlightColor) : normal

        let result = NSMutableAttributedString()
        var range: NSRange?
        for (i, w) in words.enumerated() {
            if i > 0 {
                result.append(NSAttributedString(string: " ", attributes: [.font: font, .paragraphStyle: para]))
            }
            let word = NSAttributedString(string: style.displayText(w), attributes: [
                .font: font,
                .foregroundColor: i == highlight ? hi : normal,
                .paragraphStyle: para,
            ])
            if i == highlight { range = NSRange(location: result.length, length: word.length) }
            result.append(word)
        }
        return (result, range)
    }

    /// Where `range` sits inside text laid out at `width` (top-left origin).
    private static func rect(of range: NSRange, in text: NSAttributedString, width: CGFloat) -> CGRect {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
    }

    /// A positioned caption box (always visible).
    private static func caption(_ words: [String], highlight: Int?, style: CaptionStyle,
                                fontSize: CGFloat, renderSize: CGSize) -> CALayer {
        let (text, highlightRange) = attributed(words, highlight: highlight, style: style, fontSize: fontSize)
        let maxTextWidth = renderSize.width * CGFloat(style.maxWidth)
        let bounds = text.boundingRect(with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2)
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
        if style.showBackground {
            container.backgroundColor = NSColor(style.backgroundColor)
                .withAlphaComponent(style.backgroundOpacity).cgColor
            container.cornerRadius = fontSize * 0.25
        }

        // Rounded box behind the active word. Layers use a bottom-left origin, text layout top-left.
        if style.wordBackground, let range = highlightRange {
            let r = rect(of: range, in: text, width: textSize.width)
            if !r.isEmpty {
                let insetX = fontSize * 0.14, insetY = fontSize * 0.02
                let word = CALayer()
                word.frame = CGRect(x: padX + r.minX - insetX,
                                    y: padY + textSize.height - r.maxY - insetY,
                                    width: r.width + insetX * 2,
                                    height: r.height + insetY * 2)
                word.backgroundColor = NSColor(style.wordBackgroundColor).cgColor
                word.cornerRadius = fontSize * 0.18
                container.addSublayer(word)
            }
        }

        let textLayer = CATextLayer()
        textLayer.frame = CGRect(x: padX, y: padY, width: textSize.width, height: textSize.height)
        textLayer.string = text
        textLayer.isWrapped = true
        textLayer.alignmentMode = .center
        textLayer.contentsScale = 2
        if style.showShadow {
            textLayer.shadowColor = NSColor.black.cgColor
            textLayer.shadowOpacity = 0.85
            textLayer.shadowRadius = fontSize * 0.08
            textLayer.shadowOffset = CGSize(width: 0, height: -fontSize * 0.04)
        }
        container.addSublayer(textLayer)
        return container
    }

    /// Hidden by default; visible only during [start, end) of the export timeline.
    private static func timed(_ layer: CALayer, start: Double, end: Double) -> CALayer {
        layer.opacity = 0
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        show.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
        show.duration = end - start
        show.isRemovedOnCompletion = false
        layer.add(show, forKey: "visibility")
        return layer
    }
}
