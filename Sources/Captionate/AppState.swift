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
    @Published var edit = EditOptions()

    // Language tools
    @Published var translationRequest: TranslationRequest?
    @Published var translationTarget = "en"
    @Published var isTranslating = false
    @Published private(set) var hasTextBackup = false
    private var textBackup: [CaptionSegment]?
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

    /// Shape of the output frame (preview + export).
    var canvasAspect: CGSize {
        if let r = edit.aspect.ratio { return CGSize(width: r, height: 1) }
        return videoSize
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
        textBackup = nil
        hasTextBackup = false
        currentTime = 0

        let player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
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

    /// Splits a caption into two, with `index` as the first word of the second one.
    func split(_ id: CaptionSegment.ID, beforeWord index: Int) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let seg = segments[i]
        let words = seg.timedWords()
        guard index > 0, index < words.count else { return }
        var first = CaptionSegment(start: seg.start, end: words[index].start,
                                   text: words[..<index].map(\.text).joined(separator: " "),
                                   words: Array(words[..<index]))
        var second = CaptionSegment(start: words[index].start, end: seg.end,
                                    text: words[index...].map(\.text).joined(separator: " "),
                                    words: Array(words[index...]))
        for (k, o) in seg.overrides {
            if k < index { first.overrides[k] = o } else { second.overrides[k - index] = o }
        }
        segments.replaceSubrange(i...i, with: [first, second])
    }

    func mergeWithNext(_ id: CaptionSegment.ID) {
        guard let i = segments.firstIndex(where: { $0.id == id }), i + 1 < segments.count else { return }
        let a = segments[i], b = segments[i + 1]
        let wa = a.timedWords(), wb = b.timedWords()
        var merged = CaptionSegment(start: a.start, end: max(a.end, b.end), text: a.text + " " + b.text,
                                    words: wa + wb)
        merged.overrides = a.overrides
        for (k, o) in b.overrides { merged.overrides[k + wa.count] = o }
        segments.replaceSubrange(i...(i + 1), with: [merged])
    }

    /// Replaces text in every caption; returns how many captions changed.
    @discardableResult
    func findReplace(_ find: String, with replacement: String, matchCase: Bool) -> Int {
        guard !find.isEmpty else { return 0 }
        var changed = 0
        for i in segments.indices {
            let new = segments[i].text.replacingOccurrences(
                of: find, with: replacement, options: matchCase ? [] : [.caseInsensitive])
            if new != segments[i].text {
                segments[i].text = new
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Language tools

    private func backupText() {
        guard textBackup == nil else { return }
        textBackup = segments
        hasTextBackup = true
    }

    func restoreOriginalText() {
        if let backup = textBackup { segments = backup }
        textBackup = nil
        hasTextBackup = false
    }

    /// Transliterates every caption (e.g. Roman Hinglish ↔ Devanagari). Word timings are kept.
    func convertScript(to script: TextTools.Script) {
        backupText()
        for i in segments.indices {
            segments[i].text = TextTools.convert(segments[i].text, to: script)
        }
    }

    func requestTranslation() {
        guard !segments.isEmpty else { return }
        backupText()
        translationRequest = TranslationRequest(target: Locale.Language(identifier: translationTarget))
    }

    func applyTranslation(_ translations: [String: String]) {
        for i in segments.indices {
            guard let text = translations[segments[i].id.uuidString] else { continue }
            segments[i].text = text
            segments[i].words = []          // word count changed: highlight timing is spread evenly
            segments[i].overrides = [:]
        }
    }

    // MARK: - Music

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { edit.musicURL = url }
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
        let segments = self.segments, style = self.style, edit = self.edit
        player?.pause()
        start(edit.cleanAudio || edit.normalizeLoudness ? "Cleaning audio and rendering…" : "Rendering captions into video…")
        workTask = Task {
            do {
                try await VideoExporter.export(videoURL: src, segments: segments, style: style, edit: edit,
                                               to: out) { p in
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

    func applyPreset(_ preset: StylePreset) {
        var s = preset.style
        s.hookText = style.hookText
        s.hookDuration = style.hookDuration
        s.hookColor = style.hookColor
        style = s
        grouping = preset.shortForm ? .shortForm : .standard
        regroup()
    }
}
