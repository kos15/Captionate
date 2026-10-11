import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Hook ideas written by Apple's on-device foundation model (Apple Intelligence, macOS 26+).
/// The transcript never leaves the Mac.
struct HookBrief: Equatable {
    var hooks: [String]
    var opening: String
    var tips: [String]
}

enum HookTone: String, CaseIterable, Identifiable {
    case curiosity = "Curiosity"
    case boldClaim = "Bold claim"
    case question = "Question"
    case story = "Story"
    case number = "Number / list"
    case contrarian = "Contrarian"
    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .curiosity: return "open a curiosity gap the viewer has to close by watching"
        case .boldClaim: return "lead with a bold, specific promise or result"
        case .question: return "ask a sharp question the viewer personally wants answered"
        case .story: return "drop the viewer into the middle of a moment, like a story's first line"
        case .number: return "use a specific number or list (\"3 mistakes…\", \"in 5 seconds…\")"
        case .contrarian: return "challenge a common belief the audience holds"
        }
    }
}

enum HookGenerator {
    enum Status: Equatable {
        case available
        case unavailable(String)
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac doesn't support Apple Intelligence (needs Apple silicon).")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri.")
                case .modelNotReady:
                    return .unavailable("Apple Intelligence is still downloading its model. Try again in a few minutes.")
                @unknown default:
                    return .unavailable("Apple Intelligence isn't available right now.")
                }
            }
        }
        return .unavailable("Needs macOS 26 Tahoe with Apple Intelligence.")
        #else
        return .unavailable("This build was made without the macOS 26 SDK, so Apple Intelligence isn't included.")
        #endif
    }

    /// The opening ~45 seconds matter most; the rest is sampled so the model knows the payoff.
    static func transcriptExcerpt(_ segments: [CaptionSegment]) -> (opening: String, rest: String) {
        let opening = segments.filter { $0.start < 45 }.map(\.text).joined(separator: " ")
        let rest = segments.filter { $0.start >= 45 }.map(\.text).joined(separator: " ")
        return (String(opening.prefix(1500)), String(rest.prefix(1200)))
    }

    static func generate(segments: [CaptionSegment], tone: HookTone) async throws -> HookBrief {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let excerpt = transcriptExcerpt(segments)
            let instructions = """
            You are a short-form video editor who writes scroll-stopping hooks for Reels, Shorts and TikTok.
            Write in the same language and style as the transcript. If it mixes Hindi and English (Hinglish), \
            write Hinglish in Roman script.
            Hooks must be at most 8 words, punchy, specific to the video, with no hashtags and no emojis.
            Reply ONLY in this exact format, one item per line:
            HOOK: <hook>
            HOOK: <hook>
            HOOK: <hook>
            HOOK: <hook>
            HOOK: <hook>
            OPENING: <a rewritten first spoken sentence, at most 25 words>
            TIP: <one practical tip for the first 3 seconds>
            TIP: <another tip>
            TIP: <another tip>
            """
            let prompt = """
            Style: \(tone.guidance).

            Transcript of the opening:
            \(excerpt.opening)

            Later in the video:
            \(excerpt.rest.isEmpty ? "(nothing more)" : excerpt.rest)
            """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.9))
            let brief = parse(response.content)
            guard !brief.hooks.isEmpty else { throw HookError.emptyResponse }
            return brief
        }
        #endif
        throw HookError.unavailable
    }

    /// Reads the HOOK / OPENING / TIP lines, tolerating bullets, numbering and quotes.
    static func parse(_ text: String) -> HookBrief {
        var brief = HookBrief(hooks: [], opening: "", tips: [])
        var loose: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-*•0123456789.)".contains(first) { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            func value(after prefix: String) -> String? {
                guard line.uppercased().hasPrefix(prefix) else { return nil }
                return clean(String(line.dropFirst(prefix.count)))
            }
            if let v = value(after: "HOOK:"), !v.isEmpty {
                brief.hooks.append(v)
            } else if let v = value(after: "OPENING:"), !v.isEmpty {
                brief.opening = v
            } else if let v = value(after: "TIP:"), !v.isEmpty {
                brief.tips.append(v)
            } else if line.split(separator: " ").count <= 10 {
                loose.append(clean(line))
            }
        }
        if brief.hooks.isEmpty { brief.hooks = Array(loose.prefix(5)) }
        return brief
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*"))
            .trimmingCharacters(in: .whitespaces)
    }
}

enum HookError: LocalizedError {
    case unavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Intelligence isn't available on this Mac."
        case .emptyResponse: return "Apple Intelligence didn't return any hooks. Try again or pick another style."
        }
    }
}
