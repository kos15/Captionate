import Foundation

/// Groups recognised words into readable caption segments.
enum CaptionBuilder {
    static func build(words: [Word], options: GroupingOptions) -> [CaptionSegment] {
        var segments: [CaptionSegment] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            segments.append(CaptionSegment(start: first.start, end: last.end, text: text, words: current))
            current.removeAll()
        }

        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let w = Word(text: trimmed, start: word.start, end: max(word.end, word.start + 0.05))

            if let last = current.last, let first = current.first {
                let candidateChars = current.map(\.text).joined(separator: " ").count + 1 + w.text.count
                let gap = w.start - last.end
                let endsSentence = last.text.last.map { ".?!।".contains($0) } ?? false
                if candidateChars > options.maxChars
                    || current.count >= options.maxWords
                    || w.end - first.start > options.maxDuration
                    || gap > options.pauseSplit
                    || endsSentence {
                    flush()
                }
            }
            current.append(w)
        }
        flush()

        // Hold each caption a little longer if there's room, so it doesn't flash.
        for i in segments.indices {
            let nextStart = i + 1 < segments.count ? segments[i + 1].start : segments[i].end + 0.6
            segments[i].end = min(segments[i].end + 0.3, max(segments[i].end, nextStart))
        }
        return segments
    }
}

/// SRT / WebVTT read & write.
enum SubtitleIO {
    static func srt(_ segments: [CaptionSegment], uppercase: Bool = false) -> String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start, sep: ",")) --> \(stamp(s.end, sep: ","))\n\(uppercase ? s.text.uppercased() : s.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ segments: [CaptionSegment], uppercase: Bool = false) -> String {
        "WEBVTT\n\n" + segments.map { s in
            "\(stamp(s.start, sep: ".")) --> \(stamp(s.end, sep: "."))\n\(uppercase ? s.text.uppercased() : s.text)\n"
        }.joined(separator: "\n")
    }

    private static func stamp(_ t: Double, sep: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms / 60_000) % 60
        let s = (ms / 1000) % 60
        let r = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, r)
    }

    /// Parses SRT or VTT text.
    static func parse(_ text: String) -> [CaptionSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [CaptionSegment] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIdx].components(separatedBy: "-->")
            guard parts.count == 2,
                  let a = parseStamp(parts[0]),
                  let b = parseStamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1])
            else { continue }
            let body = lines[(timeIdx + 1)...].joined(separator: " ")
            guard !body.isEmpty else { continue }
            result.append(CaptionSegment(start: a, end: b, text: body))
        }
        return result
    }

    private static func parseStamp(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = s.split(separator: ":").map(String.init)
        guard comps.count >= 2, comps.count <= 3 else { return nil }
        var total = 0.0
        for c in comps {
            guard let v = Double(c) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
