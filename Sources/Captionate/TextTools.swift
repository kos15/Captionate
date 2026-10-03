import Foundation

/// Word-level text helpers: fillers, keywords, emoji, censoring and script conversion.
enum TextTools {
    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    // MARK: Fillers

    static let fillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh",
                                       "hmm", "hm", "mm", "mmm", "mhm"]

    static func isFiller(_ word: String) -> Bool { fillers.contains(normalized(word)) }

    // MARK: Keywords (auto emphasis)

    private static let stopwords: Set<String> = [
        "about", "after", "again", "because", "before", "being", "between", "could", "doing", "during",
        "every", "having", "however", "itself", "myself", "really", "should", "something", "there",
        "these", "their", "themselves", "things", "those", "through", "though", "where", "which", "while",
        "without", "would", "yourself", "actually", "basically", "literally", "probably", "anything",
        "everything", "nothing", "someone", "everyone", "another", "around", "always", "already",
    ]

    /// A rough "important word" test: numbers, and longer words that aren't filler vocabulary.
    static func isKeyword(_ word: String) -> Bool {
        let n = normalized(word)
        if n.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        return n.count >= 6 && !stopwords.contains(n)
    }

    /// The word that carries the caption in "Big & small" mode: a manually emphasised word,
    /// else the longest keyword, else the longest word.
    static func heroIndex(_ words: [Word], overrides: [Int: WordOverride]) -> Int? {
        guard !words.isEmpty else { return nil }
        if let manual = overrides.filter({ $0.value.emphasis == true }).keys.min(), manual < words.count {
            return manual
        }
        let scored = words.enumerated().map { i, w -> (Int, Int) in
            let n = normalized(w.text).count
            return (i, isKeyword(w.text) ? n + 100 : n)
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    // MARK: Emoji

    private static let emojiMap: [String: String] = [
        "money": "💰", "cash": "💵", "rich": "🤑", "dollar": "💵", "rupee": "💸", "rupees": "💸", "paisa": "💸",
        "fire": "🔥", "hot": "🔥", "lit": "🔥", "love": "❤️", "heart": "❤️", "pyaar": "❤️",
        "happy": "😄", "funny": "😂", "laugh": "😂", "lol": "😂", "sad": "😢", "cry": "😭", "angry": "😡",
        "wow": "🤯", "crazy": "🤯", "mind": "🧠", "brain": "🧠", "smart": "🧠", "idea": "💡", "think": "🤔",
        "time": "⏰", "fast": "⚡️", "quick": "⚡️", "rocket": "🚀", "launch": "🚀", "growth": "📈", "grow": "📈",
        "success": "🏆", "win": "🏆", "winner": "🏆", "goal": "🎯", "target": "🎯", "focus": "🎯",
        "food": "🍔", "pizza": "🍕", "coffee": "☕️", "chai": "☕️", "water": "💧", "music": "🎵", "song": "🎵",
        "phone": "📱", "computer": "💻", "code": "💻", "camera": "📸", "video": "🎬", "movie": "🎬",
        "book": "📚", "learn": "📚", "study": "📚", "school": "🏫", "work": "💼", "business": "💼", "job": "💼",
        "home": "🏠", "house": "🏠", "car": "🚗", "travel": "✈️", "world": "🌍", "sun": "☀️", "night": "🌙",
        "strong": "💪", "gym": "💪", "workout": "🏋️", "health": "🩺", "sleep": "😴", "party": "🎉",
        "congratulations": "🎉", "gift": "🎁", "star": "⭐️", "magic": "✨", "secret": "🤫", "warning": "⚠️",
        "stop": "🛑", "yes": "✅", "no": "❌", "correct": "✅", "wrong": "❌", "check": "✅", "question": "❓",
        "india": "🇮🇳", "dog": "🐶", "cat": "🐱", "baby": "👶", "friend": "🤝", "friends": "🤝", "deal": "🤝",
        "eyes": "👀", "look": "👀", "watch": "👀", "listen": "👂", "speak": "🗣️", "boom": "💥", "cool": "😎",
    ]

    static func emoji(for word: String) -> String? {
        let n = normalized(word)
        if let e = emojiMap[n] { return e }
        if n.count > 3, n.hasSuffix("s"), let e = emojiMap[String(n.dropLast())] { return e }
        return nil
    }

    // MARK: Profanity

    private static let profanity: Set<String> = [
        "fuck", "fucking", "fucked", "fucker", "shit", "shitty", "bitch", "asshole", "bastard", "dick",
        "bullshit", "motherfucker", "crap", "piss", "chutiya", "chutiye", "bhenchod", "behenchod",
        "madarchod", "gandu", "bsdk", "bkl", "harami", "kamina",
    ]

    /// "fuck" → "f***" (keeps punctuation).
    static func censor(_ word: String) -> String {
        guard profanity.contains(normalized(word)) else { return word }
        var seenFirst = false
        return String(word.map { c -> Character in
            guard c.isLetter else { return c }
            if !seenFirst { seenFirst = true; return c }
            return "*"
        })
    }

    // MARK: Scripts

    enum Script: String, CaseIterable, Identifiable {
        case latin = "Roman (Latin)"
        case devanagari = "Devanagari — हिन्दी, मराठी"
        case bengali = "Bengali — বাংলা"
        case gurmukhi = "Gurmukhi — ਪੰਜਾਬੀ"
        case gujarati = "Gujarati — ગુજરાતી"
        case tamil = "Tamil — தமிழ்"
        case telugu = "Telugu — తెలుగు"
        case kannada = "Kannada — ಕನ್ನಡ"
        case malayalam = "Malayalam — മലയാളം"
        case oriya = "Odia — ଓଡ଼ିଆ"
        case arabic = "Arabic / Urdu — اردو"
        case cyrillic = "Cyrillic"
        case greek = "Greek"
        var id: String { rawValue }

        /// ICU transliterator name (used as "Latin-<name>").
        var icuName: String {
            switch self {
            case .latin: return "Latin"
            case .devanagari: return "Devanagari"
            case .bengali: return "Bengali"
            case .gurmukhi: return "Gurmukhi"
            case .gujarati: return "Gujarati"
            case .tamil: return "Tamil"
            case .telugu: return "Telugu"
            case .kannada: return "Kannada"
            case .malayalam: return "Malayalam"
            case .oriya: return "Oriya"
            case .arabic: return "Arabic"
            case .cyrillic: return "Cyrillic"
            case .greek: return "Greek"
            }
        }
    }

    /// Transliterates text into another script (e.g. Hinglish ↔ Devanagari). Same words, same timings.
    static func convert(_ text: String, to script: Script) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        if script == .latin {
            return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        }
        return latin.applyingTransform(StringTransform("Latin-\(script.icuName)"), reverse: false) ?? text
    }
}
