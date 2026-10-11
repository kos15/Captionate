import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional second pass for Hinglish transcripts: Apple's on-device model (macOS 26) tidies the rule-based
/// romanisation into the spelling people type ("aaj", "nahi", "video"). Each line must come back with the
/// same number of words, so word timings are never disturbed; lines that don't are left as they were.
enum HinglishPolisher {
    static var isAvailable: Bool { HookGenerator.status == .available }

    static func polish(_ words: [Word]) async -> [Word] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable, !words.isEmpty {
            var result = words
            let wordsPerLine = 12, linesPerRequest = 12
            let lines: [Range<Int>] = stride(from: 0, to: words.count, by: wordsPerLine).map {
                $0..<min($0 + wordsPerLine, words.count)
            }
            let instructions = """
            You fix the spelling of Hinglish transcripts (Hindi written in English letters, mixed with English).
            Use the spelling most people type in chats: aaj, kya, nahi, hai, bahut, accha, matlab, karna, yaar.
            Write English words in normal English spelling: video, basically, actually, feature, channel.
            Keep EXACTLY the same number of words on each line: one output word for each input word, same order.
            Keep punctuation attached to its word. Do not translate, add or remove words.
            Reply only with the lines, in the format: N| text
            """
            for batchStart in stride(from: 0, to: lines.count, by: linesPerRequest) {
                if Task.isCancelled { break }
                let batch = Array(lines[batchStart..<min(batchStart + linesPerRequest, lines.count)])
                let prompt = batch.enumerated().map { i, range in
                    "\(i + 1)| " + words[range].map(\.text).joined(separator: " ")
                }.joined(separator: "\n")
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1))
                    for (index, tokens) in parse(response.content) where index < batch.count {
                        let range = batch[index]
                        guard tokens.count == range.count else { continue }
                        for (offset, token) in tokens.enumerated() { result[range.lowerBound + offset].text = token }
                    }
                } catch {
                    continue    // keep the rule-based spelling for this batch
                }
            }
            return result
        }
        #endif
        return words
    }

    /// "3| aaj ka video" → (2, ["aaj", "ka", "video"]).
    private static func parse(_ text: String) -> [(Int, [String])] {
        text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2,
                  let n = Int(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*-."))),
                  n >= 1 else { return nil }
            let tokens = parts[1].split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return (n - 1, tokens)
        }
    }
}
