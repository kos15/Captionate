import Foundation

/// Turns Hindi speech recognised in Devanagari into Hinglish the way people actually type it
/// ("करना" → "karna", "आज" → "aaj", "वीडियो" → "video"), word by word so timings stay intact.
enum HinglishRomanizer {
    static func containsDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    /// Romanises every Devanagari word in a sentence; Latin words and punctuation pass through.
    static func romanize(text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { romanize(word: String($0)) }
            .joined(separator: " ")
    }

    static func romanize(word: String) -> String {
        guard containsDevanagari(word) else { return word }
        // Keep leading/trailing punctuation (including the danda) around the word.
        let punct = CharacterSet.punctuationCharacters.union(.symbols).union(CharacterSet(charactersIn: "।॥"))
        var core = Substring(word)
        var lead = "", trail = ""
        while let f = core.unicodeScalars.first, punct.contains(f) { lead.append(String(f)); core = core.dropFirst() }
        while let l = core.unicodeScalars.last, punct.contains(l) { trail = String(l) + trail; core = core.dropLast() }
        func latinPunctuation(_ s: String) -> String {
            s.replacingOccurrences(of: "।", with: ".").replacingOccurrences(of: "॥", with: ".")
        }
        lead = latinPunctuation(lead)
        trail = latinPunctuation(trail)
        let key = String(core)
        let roman = dictionary[key] ?? transliterate(key)
        return lead + roman + trail
    }

    // MARK: Rule-based transliteration with Hindi schwa deletion

    private static let consonants: [Character: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n", "च": "ch", "छ": "chh", "ज": "j", "झ": "jh",
        "ञ": "n", "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n", "त": "t", "थ": "th", "द": "d",
        "ध": "dh", "न": "n", "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r",
        "ल": "l", "व": "v", "श": "sh", "ष": "sh", "स": "s", "ह": "h", "ळ": "l",
    ]
    /// Consonant + nukta (Urdu/Persian sounds).
    private static let nuktaConsonants: [Character: String] = [
        "क": "q", "ख": "kh", "ग": "gh", "ज": "z", "फ": "f", "ड": "d", "ढ": "dh", "य": "y",
    ]
    /// Precomposed nukta letters → base letter.
    private static let precomposed: [Character: Character] = [
        "\u{0958}": "क", "\u{0959}": "ख", "\u{095A}": "ग", "\u{095B}": "ज",
        "\u{095C}": "ड", "\u{095D}": "ढ", "\u{095E}": "फ", "\u{095F}": "य",
    ]
    private static let vowels: [Character: String] = [
        "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ऋ": "ri", "ए": "e", "ऐ": "ai",
        "ओ": "o", "औ": "au", "ऑ": "o", "ऍ": "e",
    ]
    private static let matras: [Character: String] = [
        "\u{093E}": "aa", "\u{093F}": "i", "\u{0940}": "ee", "\u{0941}": "u", "\u{0942}": "oo",
        "\u{0943}": "ri", "\u{0947}": "e", "\u{0948}": "ai", "\u{094B}": "o", "\u{094C}": "au",
        "\u{0949}": "o", "\u{0945}": "e",
    ]
    private static let digits: [Character: String] = [
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4", "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
    ]
    private static let virama: Character = "\u{094D}", nukta: Character = "\u{093C}"
    private static let anusvara: Character = "\u{0902}", chandrabindu: Character = "\u{0901}", visarga: Character = "\u{0903}"

    private enum Vowel: Equatable {
        case none            // virama: bare consonant
        case schwa           // inherent "a", may be dropped
        case explicit(String)
    }

    private struct Syllable {
        var consonant: String
        var vowel: Vowel
        var coda: String = ""   // "N" (nasal) or "h" (visarga)
    }

    static func transliterate(_ word: String) -> String {
        // Characters, with precomposed nukta letters split into base + nukta.
        var chars: [Character] = []
        for c in word {
            // Swift may merge a consonant with following combining marks into one Character;
            // walk scalars so matras, viramas and nuktas are seen individually.
            for scalar in c.unicodeScalars {
                let ch = Character(scalar)
                if let base = precomposed[ch] { chars.append(base); chars.append(nukta) } else { chars.append(ch) }
            }
        }

        var syllables: [Syllable] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let plain = consonants[c] {
                var roman = plain
                i += 1
                if i < chars.count, chars[i] == nukta {
                    roman = nuktaConsonants[c] ?? plain
                    i += 1
                }
                if i < chars.count, chars[i] == virama {
                    syllables.append(Syllable(consonant: roman, vowel: .none))
                    i += 1
                } else if i < chars.count, let m = matras[chars[i]] {
                    syllables.append(Syllable(consonant: roman, vowel: .explicit(m)))
                    i += 1
                } else {
                    syllables.append(Syllable(consonant: roman, vowel: .schwa))
                }
            } else if let v = vowels[c] {
                syllables.append(Syllable(consonant: "", vowel: .explicit(v)))
                i += 1
            } else if c == anusvara || c == chandrabindu {
                if !syllables.isEmpty { syllables[syllables.count - 1].coda = "N" }
                i += 1
            } else if c == visarga {
                if !syllables.isEmpty { syllables[syllables.count - 1].coda = "h" }
                i += 1
            } else if let d = digits[c] {
                syllables.append(Syllable(consonant: d, vowel: .none))
                i += 1
            } else if c == nukta || c == virama || c == "\u{200C}" || c == "\u{200D}" {
                i += 1
            } else {
                syllables.append(Syllable(consonant: String(c), vowel: .none))
                i += 1
            }
        }

        // Schwa deletion, right to left: drop the inherent "a" at the end of a word, and in the middle
        // between two voiced syllables (VC_CV) — unless that would stack three consonants.
        let n = syllables.count
        var keep = [Bool](repeating: true, count: n)
        func hasVowel(_ k: Int) -> Bool {
            switch syllables[k].vowel {
            case .none: return false
            case .schwa: return keep[k]
            case .explicit: return true
            }
        }
        for k in stride(from: n - 1, through: 1, by: -1) where syllables[k].vowel == .schwa {
            guard syllables[k].coda.isEmpty else { continue }
            if k == n - 1 {
                keep[k] = syllables[k].consonant.isEmpty
                continue
            }
            let previous = syllables[k - 1]
            let clusterBefore = !previous.coda.isEmpty || (k >= 2 && syllables[k - 2].vowel == .none)
            if hasVowel(k - 1) && hasVowel(k + 1) && !syllables[k + 1].consonant.isEmpty && !clusterBefore {
                keep[k] = false
            }
        }

        var out = ""
        for (k, s) in syllables.enumerated() {
            let last = k == n - 1
            var v: String
            switch s.vowel {
            case .none: v = ""
            case .schwa: v = keep[k] ? "a" : ""
            case .explicit(let e): v = e
            }
            // Hinglish spelling: word-final long vowels are written short ("tha", "rahi", "hu").
            if last && !s.consonant.isEmpty {
                if v == "aa" { v = "a" } else if v == "ee" { v = "i" } else if v == "oo" { v = "u" }
            }
            out += s.consonant + v
            if s.coda == "N" {
                let next = k + 1 < n ? syllables[k + 1].consonant : ""
                out += ["p", "b", "m"].contains(where: { next.hasPrefix($0) }) ? "m" : "n"
            } else if s.coda == "h" {
                out += "h"
            }
        }
        return out.replacingOccurrences(of: "chchh", with: "cch")
    }

    // MARK: Common words and English loanwords

    /// Spellings people actually use, and English words recognised in Devanagari back in English.
    static let dictionary: [String: String] = [
        // Everyday Hindi
        "है": "hai", "हैं": "hain", "हूँ": "hoon", "हूं": "hoon", "हो": "ho", "था": "tha", "थी": "thi", "थे": "the",
        "नहीं": "nahi", "ना": "na", "न": "na", "क्या": "kya", "क्यों": "kyun", "क्यूं": "kyun", "क्योंकि": "kyunki",
        "कैसे": "kaise", "कैसा": "kaisa", "कैसी": "kaisi", "कहाँ": "kahan", "कहां": "kahan", "यहाँ": "yahan",
        "यहां": "yahan", "वहाँ": "wahan", "वहां": "wahan", "कब": "kab", "जब": "jab", "तब": "tab", "अब": "ab",
        "मैं": "main", "में": "mein", "मुझे": "mujhe", "मेरा": "mera", "मेरी": "meri", "मेरे": "mere",
        "तुम": "tum", "तुम्हें": "tumhe", "तुम्हारा": "tumhara", "तू": "tu", "तेरा": "tera", "तेरी": "teri",
        "आप": "aap", "आपका": "aapka", "आपकी": "aapki", "आपके": "aapke", "आपको": "aapko",
        "हम": "hum", "हमें": "humein", "हमारा": "humara", "हमारी": "humari", "हमारे": "humare",
        "वो": "woh", "वह": "woh", "वे": "woh", "ये": "ye", "यह": "yeh", "इस": "is", "उस": "us", "इसे": "ise",
        "उसे": "use", "इसका": "iska", "उसका": "uska", "इसकी": "iski", "उसकी": "uski", "इनका": "inka", "उनका": "unka",
        "का": "ka", "की": "ki", "के": "ke", "को": "ko", "से": "se", "पर": "par", "तक": "tak", "भी": "bhi",
        "तो": "toh", "ही": "hi", "और": "aur", "या": "ya", "लेकिन": "lekin", "पर्": "par", "अगर": "agar",
        "एक": "ek", "दो": "do", "तीन": "teen", "चार": "chaar", "पांच": "paanch", "पाँच": "paanch", "दस": "das",
        "सौ": "sau", "हज़ार": "hazaar", "हजार": "hazaar", "लाख": "lakh", "करोड़": "crore",
        "कर": "kar", "करो": "karo", "करना": "karna", "करें": "karein", "करते": "karte", "करता": "karta",
        "करती": "karti", "किया": "kiya", "की।": "ki.", "रहा": "raha", "रही": "rahi", "रहे": "rahe",
        "गया": "gaya", "गई": "gayi", "गए": "gaye", "जा": "ja", "जाना": "jana", "जाओ": "jao", "आना": "aana",
        "आओ": "aao", "आया": "aaya", "आई": "aayi", "देखो": "dekho", "देखा": "dekha", "देखिए": "dekhiye",
        "बोलो": "bolo", "बोला": "bola", "सुनो": "suno", "चलो": "chalo", "चल": "chal", "बताओ": "batao",
        "बताता": "batata", "सकते": "sakte", "सकता": "sakta", "सकती": "sakti", "चाहिए": "chahiye",
        "अच्छा": "accha", "अच्छी": "acchi", "अच्छे": "acche", "बहुत": "bahut", "सब": "sab", "सबसे": "sabse",
        "कुछ": "kuch", "कोई": "koi", "सिर्फ": "sirf", "सिर्फ़": "sirf", "ज़्यादा": "zyada", "ज्यादा": "zyada",
        "कम": "kam", "बड़ा": "bada", "बड़ी": "badi", "छोटा": "chhota", "छोटी": "chhoti", "नया": "naya",
        "नई": "nayi", "पुराना": "purana", "आज": "aaj", "कल": "kal", "अभी": "abhi", "फिर": "phir",
        "पहले": "pehle", "बाद": "baad", "साथ": "saath", "लिए": "liye", "लिये": "liye", "वाला": "wala",
        "वाली": "wali", "वाले": "wale", "यार": "yaar", "भाई": "bhai", "दोस्त": "dost", "दोस्तों": "doston",
        "मतलब": "matlab", "बात": "baat", "बातें": "baatein", "चीज़": "cheez", "चीज": "cheez", "चीज़ें": "cheezein",
        "लोग": "log", "लोगों": "logon", "पैसा": "paisa", "पैसे": "paise", "काम": "kaam", "समय": "samay",
        "ठीक": "theek", "पता": "pata", "हाँ": "haan", "हां": "haan", "जी": "ji", "नमस्ते": "namaste",
        "धन्यवाद": "dhanyavaad", "शुक्रिया": "shukriya", "ज़िंदगी": "zindagi", "जिंदगी": "zindagi",
        "पहुँचना": "pahunchna", "पहुंचना": "pahunchna", "पहुँच": "pahunch", "पहुंच": "pahunch",
        "अस्पताल": "aspatal", "दिन": "din", "रात": "raat", "घर": "ghar", "अपना": "apna", "अपनी": "apni", "अपने": "apne",
        "जो": "jo", "जैसे": "jaise", "वैसे": "waise", "ऐसा": "aisa", "ऐसे": "aise", "ऐसी": "aisi",
        // English loanwords recognised in Devanagari
        "वीडियो": "video", "वीडियोज़": "videos", "चैनल": "channel", "सब्सक्राइब": "subscribe", "लाइक": "like",
        "कमेंट": "comment", "कमेंट्स": "comments", "शेयर": "share", "फोन": "phone", "फ़ोन": "phone",
        "मोबाइल": "mobile", "ऐप": "app", "ऐप्स": "apps", "बेसिकली": "basically", "टेक्निकली": "technically",
        "एक्चुअली": "actually", "लिटरली": "literally", "सीरियसली": "seriously", "फीचर": "feature",
        "फीचर्स": "features", "ट्राय": "try", "ट्राई": "try", "वर्क": "work", "वर्क्स": "works",
        "कंटेंट": "content", "क्रिएटर": "creator", "क्रिएटर्स": "creators", "बिज़नेस": "business",
        "बिजनेस": "business", "मार्केटिंग": "marketing", "टाइम": "time", "प्रॉब्लम": "problem",
        "सॉल्यूशन": "solution", "आइडिया": "idea", "ओके": "okay", "सॉरी": "sorry", "थैंक": "thank",
        "थैंक्स": "thanks", "यू": "you", "गाइज़": "guys", "गाइज": "guys", "हेलो": "hello", "हाय": "hi",
        "लाइफ": "life", "चेंजिंग": "changing", "सीक्रेट": "secret", "स्टेप": "step", "स्टेप्स": "steps",
        "टिप्स": "tips", "बेस्ट": "best", "फ्री": "free", "लिंक": "link", "डिस्क्रिप्शन": "description",
        "इंस्टाग्राम": "Instagram", "यूट्यूब": "YouTube", "रील": "reel", "रील्स": "reels", "शॉर्ट्स": "shorts",
        "एआई": "AI", "कंप्यूटर": "computer", "लैपटॉप": "laptop", "मैक": "Mac", "आईफोन": "iPhone",
        "ऑनलाइन": "online", "ऑफलाइन": "offline", "सिंपल": "simple", "इज़ी": "easy", "स्पेशल": "special",
        "पार्ट": "part", "नेक्स्ट": "next", "लास्ट": "last", "फर्स्ट": "first", "ग्रोथ": "growth",
        "सक्सेस": "success", "मनी": "money", "इन्वेस्ट": "invest", "स्टॉक": "stock", "मार्केट": "market",
        "टेक": "tech", "कोड": "code", "वेबसाइट": "website", "डेटा": "data", "टीम": "team",
        "प्रोजेक्ट": "project", "क्लाइंट": "client", "कस्टमर": "customer", "प्रोडक्ट": "product",
        "सर्विस": "service", "ब्रांड": "brand", "डील": "deal", "ऑफर": "offer", "स्टार्ट": "start",
        "स्टार्टअप": "startup", "सेटअप": "setup", "एडिट": "edit", "एडिटिंग": "editing", "कैप्शन": "caption",
        "कैप्शंस": "captions", "लाइव": "live", "वेलकम": "welcome", "बैक": "back", "ऑल": "all", "गुड": "good",
        "नाइस": "nice", "कूल": "cool", "लुक": "look", "वाओ": "wow", "वॉव": "wow", "क्रेज़ी": "crazy",
        "क्रेजी": "crazy", "सुपर": "super", "स्कूल": "school", "कॉलेज": "college", "ऑफिस": "office",
        "जॉब": "job", "सैलरी": "salary", "प्लान": "plan", "प्लीज़": "please", "प्लीज": "please",
        "रियल": "real", "रियली": "really", "मेन": "main", "पॉइंट": "point", "टॉपिक": "topic",
        "क्वेश्चन": "question", "आंसर": "answer", "इंटरनेट": "internet", "गेम": "game", "मूवी": "movie",
        "म्यूजिक": "music", "म्यूज़िक": "music", "फ़ोटो": "photo", "फोटो": "photo", "कैमरा": "camera",
        "डॉक्टर": "doctor", "हेल्थ": "health", "जिम": "gym", "डाइट": "diet", "फूड": "food", "ट्रैवल": "travel",
    ]
}
