import Foundation
import AVFoundation
import Speech

enum TranscriberError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable(String)
    case noAudioTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable(let id):
            return "Speech recognition isn't available for \(id). Try another language, or download it in System Settings → Keyboard → Dictation."
        case .noAudioTrack:
            return "This video has no audio track."
        case .exportFailed(let msg):
            return "Couldn't extract audio: \(msg)"
        }
    }
}

/// Transcribes a video's audio entirely on-device.
///
/// On macOS 26 the newer long-form speech model (SpeechAnalyzer) is used when it supports the language —
/// it is noticeably more accurate on English. Otherwise Apple's classic recogniser runs on overlapping
/// chunks: one request degrades on long files, and cutting at fixed points would split words in half,
/// so each chunk overlaps the next and every word is kept from the chunk that heard it whole.
final class Transcriber {
    static let chunkSeconds: Double = 45
    static let overlapSeconds: Double = 4

    /// Pseudo-language: recognise Hindi, write it in Roman (English) letters, Hinglish style.
    static let hinglishRoman = Locale(identifier: "hi-Latn-IN")
    static let hindi = Locale(identifier: "hi-IN")

    static func isHinglishRoman(_ l: Locale) -> Bool { l.identifier == hinglishRoman.identifier }

    /// Whether this build can use the macOS 26 speech model (it still checks the language at run time).
    static var advancedModelAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static func supportedLocales() -> [Locale] {
        let all = SFSpeechRecognizer.supportedLocales()
        let sorted = all.sorted { displayName($0) < displayName($1) }
        let hasHindi = all.contains { $0.identifier == "hi-IN" || $0.identifier == "hi_IN" }
        return hasHindi ? [hinglishRoman] + sorted : sorted
    }

    static func displayName(_ l: Locale) -> String {
        if isHinglishRoman(l) { return "Hinglish — Roman script (aaj, kya, video)" }
        return Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Returns word timings for the whole video. `progress` receives 0...1.
    /// `vocabulary` holds names and special words, used as recognition hints and to fix their spelling.
    static func transcribe(videoURL: URL,
                           locale: Locale,
                           vocabulary: [String] = [],
                           useAdvancedModel: Bool = true,
                           progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        guard await requestAuthorization() else { throw TranscriberError.notAuthorized }
        let romanize = isHinglishRoman(locale)
        let speechLocale = romanize ? hindi : locale

        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriberError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captionate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var words: [Word]?
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), useAdvancedModel, !romanize,
           let modelLocale = await AdvancedTranscriber.supportedLocale(for: speechLocale) {
            do {
                progress(0, "Preparing audio…")
                let audioURL = tmpDir.appendingPathComponent("audio.m4a")
                try await exportAudio(asset: asset, start: 0, length: duration, to: audioURL)
                words = try await AdvancedTranscriber.transcribe(audioURL: audioURL, locale: modelLocale,
                                                                 duration: duration, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                words = nil   // fall back to the classic recogniser below
            }
        }
        #endif

        if words == nil {
            guard let recognizer = SFSpeechRecognizer(locale: speechLocale), recognizer.isAvailable else {
                throw TranscriberError.recognizerUnavailable(speechLocale.identifier)
            }
            words = try await transcribeInChunks(asset: asset, duration: duration, recognizer: recognizer,
                                                 vocabulary: vocabulary, tmpDir: tmpDir, progress: progress)
        }
        progress(1, "Done")

        var result = cleanTimings(words ?? [])
        if romanize {
            result = result.map { Word(text: HinglishRomanizer.romanize(word: $0.text), start: $0.start, end: $0.end) }
        }
        return applyVocabulary(vocabulary, to: result)
    }

    private static func transcribeInChunks(asset: AVAsset, duration: Double, recognizer: SFSpeechRecognizer,
                                           vocabulary: [String], tmpDir: URL,
                                           progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        var words: [Word] = []
        let chunkCount = max(1, Int(ceil((duration - overlapSeconds / 2) / chunkSeconds)))

        for i in 0..<chunkCount {
            try Task.checkCancellation()
            let start = Double(i) * chunkSeconds
            let isLast = i == chunkCount - 1
            let length = isLast ? duration - start : min(chunkSeconds + overlapSeconds, duration - start)
            if length < 0.2 { break }
            progress(Double(i) / Double(chunkCount),
                     "Transcribing \(formatTimestamp(start)) – \(formatTimestamp(start + length))")

            // Words whose middle falls in the first half of an overlap belong to the earlier chunk.
            let keepFrom = i == 0 ? -Double.infinity : start + overlapSeconds / 2
            let keepUntil = isLast ? Double.infinity : start + chunkSeconds + overlapSeconds / 2

            let chunkURL = tmpDir.appendingPathComponent("chunk-\(i).m4a")
            try await exportAudio(asset: asset, start: start, length: length, to: chunkURL)
            let chunkWords = try await recognizeWithRetry(url: chunkURL, recognizer: recognizer, vocabulary: vocabulary)
            try? FileManager.default.removeItem(at: chunkURL)
            for w in chunkWords {
                let word = Word(text: w.text, start: w.start + start, end: w.end + start)
                let mid = (word.start + word.end) / 2
                guard mid >= keepFrom, mid < keepUntil else { continue }
                if let last = words.last, isSameWord(last, word) { continue }   // heard by both chunks
                words.append(word)
            }
        }
        return words
    }

    private static func isSameWord(_ a: Word, _ b: Word) -> Bool {
        abs(a.start - b.start) < 0.35 && normalized(a.text) == normalized(b.text)
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Keeps timings in order and gives every word a visible duration without overlapping the next one.
    static func cleanTimings(_ input: [Word]) -> [Word] {
        var words = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for i in words.indices {
            if i > 0, words[i].start < words[i - 1].start { words[i].start = words[i - 1].start }
            if words[i].end < words[i].start + 0.05 { words[i].end = words[i].start + 0.05 }
        }
        for i in words.indices.dropLast() where words[i].end > words[i + 1].start {
            words[i].end = max(words[i].start + 0.02, words[i + 1].start)
        }
        return words
    }

    /// Gives custom words their exact spelling ("iphone" → "iPhone", "captionate" → "Captionate"),
    /// keeping any punctuation stuck to the word.
    static func applyVocabulary(_ vocabulary: [String], to words: [Word]) -> [Word] {
        let map = Dictionary(vocabulary.filter { !$0.contains(" ") }.map { (normalized($0), $0) },
                             uniquingKeysWith: { a, _ in a })
        guard !map.isEmpty else { return words }
        return words.map { w in
            guard let fixed = map[normalized(w.text)] else { return w }
            let core = w.text.trimmingCharacters(in: .punctuationCharacters)
            guard let range = w.text.range(of: core) else { return w }
            return Word(text: w.text.replacingCharacters(in: range, with: fixed), start: w.start, end: w.end)
        }
    }

    private static func exportAudio(asset: AVAsset, start: Double, length: Double, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.exportFailed("export session unavailable")
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        await session.export()
        if session.status != .completed {
            throw TranscriberError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    /// The recogniser occasionally fails a chunk for no lasting reason; one retry saves the whole run.
    private static func recognizeWithRetry(url: URL, recognizer: SFSpeechRecognizer,
                                           vocabulary: [String]) async throws -> [Word] {
        do {
            return try await recognize(url: url, recognizer: recognizer, vocabulary: vocabulary)
        } catch {
            try Task.checkCancellation()
            return try await recognize(url: url, recognizer: recognizer, vocabulary: vocabulary)
        }
    }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer, vocabulary: [String]) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if !vocabulary.isEmpty { request.contextualStrings = Array(vocabulary.prefix(100)) }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            let lock = NSLock()
            func finish(_ result: Result<[Word], Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                cont.resume(with: result)
            }

            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    finish(.success(words))
                } else if let error {
                    let ns = error as NSError
                    // 1110 = "No speech detected" (silent chunk) — not a real failure.
                    if ns.code == 1110 || ns.code == 203 {
                        finish(.success([]))
                    } else {
                        finish(.failure(error))
                    }
                }
            }
        }
    }
}

#if compiler(>=6.2)
/// macOS 26's long-form speech model. It takes the whole file at once (no chunk seams) and
/// reports a time range for every word.
@available(macOS 26.0, *)
enum AdvancedTranscriber {
    static func supportedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    static func transcribe(audioURL: URL, locale: Locale, duration: Double,
                           progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0, "Downloading the speech model (one time)…")
            try await request.downloadAndInstall()
        }
        progress(0, "Transcribing with Apple's speech model…")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioURL)
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            var endsWithSpace = true
            for try await result in transcriber.results {
                append(result.text, to: &words, endsWithSpace: &endsWithSpace)
                let reached = result.range.end.seconds
                if reached.isFinite, duration > 0 {
                    progress(min(0.99, reached / duration),
                             "Transcribing \(formatTimestamp(reached)) / \(formatTimestamp(duration))")
                }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await withTaskCancellationHandler {
            try await collector.value
        } onCancel: {
            collector.cancel()
        }
    }

    /// Splits a result into timed words. Runs carry time ranges; a run may hold part of a word,
    /// several words, or untimed punctuation, which is glued onto the word before it.
    private static func append(_ text: AttributedString, to words: inout [Word], endsWithSpace: inout Bool) {
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            let startsWithSpace = piece.first?.isWhitespace ?? false
            var tokens = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let range = run.audioTimeRange
            let start = range.map { $0.start.seconds } ?? (words.last?.end ?? 0)
            let end = range.map { $0.end.seconds } ?? start

            if !tokens.isEmpty, !startsWithSpace, !endsWithSpace, !words.isEmpty {
                words[words.count - 1].text += tokens.removeFirst()
                if range != nil { words[words.count - 1].end = max(words[words.count - 1].end, end) }
            }
            if !tokens.isEmpty {
                let step = max(0, end - start) / Double(tokens.count)
                for (i, t) in tokens.enumerated() {
                    words.append(Word(text: t, start: start + Double(i) * step, end: start + Double(i + 1) * step))
                }
            }
            endsWithSpace = piece.last?.isWhitespace ?? false
        }
        endsWithSpace = true   // each result is a separate phrase
    }
}
#endif
