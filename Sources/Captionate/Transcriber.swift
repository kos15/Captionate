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

/// Transcribes a video's audio with Apple's Speech framework, entirely on-device
/// when the language supports it. Long audio is cut into chunks because a single
/// recognition request degrades on long files.
final class Transcriber {
    static let chunkSeconds: Double = 50

    static func supportedLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { displayName($0) < displayName($1) }
    }

    static func displayName(_ l: Locale) -> String {
        Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Returns word timings for the whole video. `progress` receives 0...1.
    static func transcribe(videoURL: URL,
                           locale: Locale,
                           progress: @escaping (Double, String) -> Void) async throws -> [Word] {
        guard await requestAuthorization() else { throw TranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable(locale.identifier)
        }

        let asset = AVURLAsset(url: videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriberError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captionate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var words: [Word] = []
        let chunkCount = max(1, Int(ceil(duration / chunkSeconds)))

        for i in 0..<chunkCount {
            try Task.checkCancellation()
            let start = Double(i) * chunkSeconds
            let length = min(chunkSeconds, duration - start)
            if length < 0.2 { break }
            progress(Double(i) / Double(chunkCount),
                     "Transcribing \(formatTimestamp(start)) – \(formatTimestamp(start + length))")

            let chunkURL = tmpDir.appendingPathComponent("chunk-\(i).m4a")
            try await exportAudio(asset: asset, start: start, length: length, to: chunkURL)
            let chunkWords = try await recognize(url: chunkURL, recognizer: recognizer)
            words += chunkWords.map { Word(text: $0.text, start: $0.start + start, end: $0.end + start) }
        }
        progress(1, "Done")
        return words
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

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> [Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
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
