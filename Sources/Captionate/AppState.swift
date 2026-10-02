import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    // Video
    @Published var videoURL: URL?
    @Published var player: AVPlayer?
    @Published var videoSize: CGSize = CGSize(width: 16, height: 9)
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0

    // Captions
    @Published var words: [Word] = []
    @Published var segments: [CaptionSegment] = []
    @Published var style = CaptionStyle()
    @Published var grouping = GroupingOptions.standard
    @Published var locale: Locale

    // Work status
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var errorMessage: String?

    let locales: [Locale]
    private var timeObserver: Any?
    private var workTask: Task<Void, Never>?

    init() {
        locales = Transcriber.supportedLocales()
        let preferred = ["en-IN", "en_IN", "en-US", "en_US"]
        locale = preferred.lazy.compactMap { id in
            Transcriber.supportedLocales().first { $0.identifier == id }
        }.first ?? Locale(identifier: "en-US")
    }

    var activeSegment: CaptionSegment? {
        segments.first { currentTime >= $0.start && currentTime < $0.end }
    }

    // MARK: - Loading

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        workTask?.cancel()
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        videoURL = url
        words = []
        segments = []
        currentTime = 0

        let player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated { self?.currentTime = t.seconds }
        }
        self.player = player

        Task {
            let asset = AVURLAsset(url: url)
            do {
                duration = try await asset.load(.duration).seconds
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let t = try await track.load(.preferredTransform)
                    let r = CGRect(origin: .zero, size: size).applying(t)
                    videoSize = CGSize(width: abs(r.width), height: abs(r.height))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Transcription

    func transcribe() {
        guard let url = videoURL, !isWorking else { return }
        let locale = self.locale
        start("Preparing audio…")
        workTask = Task {
            do {
                let words = try await Transcriber.transcribe(videoURL: url, locale: locale) { p, msg in
                    Task { @MainActor in
                        self.progress = p
                        self.statusMessage = msg
                    }
                }
                self.words = words
                regroup()
                if words.isEmpty { errorMessage = "No speech was detected. Check the language setting." }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            finish()
        }
    }

    func regroup() {
        guard !words.isEmpty else { return }
        segments = CaptionBuilder.build(words: words, options: grouping)
    }

    func cancelWork() { workTask?.cancel() }

    // MARK: - Editing

    func seek(to t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func delete(_ id: CaptionSegment.ID) {
        segments.removeAll { $0.id == id }
    }

    func addCaptionAtPlayhead() {
        let start = currentTime
        let seg = CaptionSegment(start: start, end: min(duration > 0 ? duration : start + 2, start + 2), text: "New caption")
        let idx = segments.firstIndex { $0.start > start } ?? segments.count
        segments.insert(seg, at: idx)
    }

    // MARK: - Import / export

    func importSubtitles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText,
                                     UTType(filenameExtension: "vtt") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = SubtitleIO.parse(text)
            if parsed.isEmpty { errorMessage = "No captions found in that file." } else { segments = parsed }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportSubtitles(vtt: Bool) {
        guard let out = savePanel(ext: vtt ? "vtt" : "srt") else { return }
        let text = vtt ? SubtitleIO.vtt(segments, uppercase: style.uppercase)
                       : SubtitleIO.srt(segments, uppercase: style.uppercase)
        do { try text.write(to: out, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportVideo() {
        guard let src = videoURL, !segments.isEmpty, !isWorking,
              let out = savePanel(ext: "mp4") else { return }
        let segments = self.segments, style = self.style
        player?.pause()
        start("Rendering captions into video…")
        workTask = Task {
            do {
                try await VideoExporter.export(videoURL: src, segments: segments, style: style, to: out) { p in
                    Task { @MainActor in self.progress = p }
                }
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            finish()
        }
    }

    private func savePanel(ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        let base = videoURL?.deletingPathExtension().lastPathComponent ?? "captions"
        panel.nameFieldStringValue = ext == "mp4" ? "\(base)-captioned.mp4" : "\(base).\(ext)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start(_ msg: String) {
        isWorking = true
        progress = 0
        statusMessage = msg
        errorMessage = nil
    }

    private func finish() {
        isWorking = false
        statusMessage = ""
        workTask = nil
    }

    // MARK: - Presets

    func applyPreset(_ name: String) {
        var s = CaptionStyle()
        switch name {
        case "Shorts":
            s.fontName = "Avenir Next"
            s.fontScale = 0.065
            s.showBackground = false
            s.uppercase = true
            s.wordHighlight = true
            s.position = .middle
            grouping = .shortForm
        case "WordBox":
            s.fontName = "Avenir Next"
            s.fontScale = 0.065
            s.showBackground = false
            s.uppercase = true
            s.wordBackground = true
            s.position = .middle
            grouping = .shortForm
        case "Minimal":
            s.fontScale = 0.045
            s.bold = false
            s.showBackground = false
            grouping = .standard
        default: // Classic
            grouping = .standard
        }
        style = s
        regroup()
    }
}
