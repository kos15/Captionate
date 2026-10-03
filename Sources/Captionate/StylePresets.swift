import SwiftUI

/// A ready-made caption look. Applying one replaces the style (the hook title is kept).
struct StylePreset: Identifiable {
    let name: String
    var category: Category
    /// Short-form presets split captions into a few words at a time.
    var shortForm: Bool = true
    let configure: (inout CaptionStyle) -> Void

    var id: String { name }
    var style: CaptionStyle {
        var s = CaptionStyle()
        configure(&s)
        return s
    }

    enum Category: String, CaseIterable, Identifiable {
        case shortForm = "Shorts & Reels"
        case wordArt = "Word art"
        case classic = "Classic & subtitles"
        var id: String { rawValue }
    }

    private static let yellow = Color(red: 1.0, green: 0.85, blue: 0.1)
    private static let green = Color(red: 0.3, green: 1.0, blue: 0.45)

    static let all: [StylePreset] = [
        // Shorts & Reels
        StylePreset(name: "Hormozi", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.07; s.showBackground = false; s.uppercase = true
            s.autoEmphasis = true; s.emphasisColor = yellow; s.wordArt = .outline; s.artColor = .black
            s.effect = .popWords; s.position = .middle
        },
        StylePreset(name: "MrBeast", category: .shortForm) { s in
            s.fontName = "Impact"; s.fontScale = 0.075; s.showBackground = false; s.uppercase = true
            s.wordArt = .comic; s.artDepthColor = .black; s.wordHighlight = true; s.highlightColor = yellow
            s.effect = .bounce; s.position = .middle
        },
        StylePreset(name: "Word Pop", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.068; s.showBackground = false; s.uppercase = true
            s.effect = .popWords; s.position = .middle
        },
        StylePreset(name: "Shorts", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.uppercase = true
            s.wordHighlight = true; s.position = .middle
        },
        StylePreset(name: "Karaoke", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.06; s.wordHighlight = true; s.highlightColor = green
            s.position = .middle
        },
        StylePreset(name: "Highlighted", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.uppercase = true
            s.wordBackground = true; s.wordBackgroundColor = yellow; s.wordHighlight = true
            s.highlightColor = .black; s.position = .middle
        },
        StylePreset(name: "Word Box", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.uppercase = true
            s.wordBackground = true; s.position = .middle
        },
        StylePreset(name: "Bold Box", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.06; s.backgroundColor = .white; s.backgroundOpacity = 1
            s.textColor = .black; s.showShadow = false; s.uppercase = true; s.wordHighlight = true
            s.highlightColor = Color(red: 0.85, green: 0.1, blue: 0.2); s.effect = .pop; s.position = .middle
        },
        StylePreset(name: "Bounce", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.uppercase = true
            s.wordHighlight = true; s.highlightColor = green; s.effect = .bounce; s.position = .middle
        },
        StylePreset(name: "Emoji Pop", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.062; s.showBackground = false; s.uppercase = true
            s.autoEmoji = true; s.autoEmphasis = true; s.emphasisColor = yellow; s.effect = .popWords
            s.position = .middle
        },
        StylePreset(name: "Big & Small", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.06; s.showBackground = false; s.uppercase = true
            s.heroWord = true; s.heroFontName = "Impact"; s.heroScale = 1.9; s.smallScale = 0.65
            s.heroColor = yellow; s.effect = .popWords; s.position = .middle
        },
        StylePreset(name: "Editorial", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.bold = false; s.fontScale = 0.06; s.showBackground = false
            s.heroWord = true; s.heroFontName = "Didot"; s.heroScale = 1.8; s.smallScale = 0.7
            s.heroColor = .white; s.effect = .fade; s.position = .middle
        },
        StylePreset(name: "Script Mix", category: .shortForm) { s in
            s.fontName = "Futura"; s.fontScale = 0.058; s.showBackground = false; s.uppercase = false
            s.heroWord = true; s.heroFontName = "Snell Roundhand"; s.heroScale = 2.0; s.smallScale = 0.7
            s.heroColor = Color(red: 1.0, green: 0.55, blue: 0.75); s.effect = .slideUp; s.position = .middle
        },
        StylePreset(name: "Typewriter", category: .shortForm, shortForm: false) { s in
            s.fontName = "Courier New"; s.effect = .typewriter
        },
        StylePreset(name: "Slide", category: .shortForm) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.06; s.effect = .slideUp; s.position = .middle
        },

        // Word art
        StylePreset(name: "Neon", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.showShadow = false
            s.uppercase = true; s.wordArt = .neon; s.artColor = Color(red: 0.1, green: 0.9, blue: 1.0)
            s.effect = .popWords; s.position = .middle
        },
        StylePreset(name: "Deep Glow", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false
            s.textColor = Color(red: 0.75, green: 0.85, blue: 1.0); s.wordArt = .glow; s.effect = .fade
            s.position = .middle
        },
        StylePreset(name: "Glitch", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.068; s.showBackground = false; s.uppercase = true
            s.wordArt = .glitch; s.effect = .pop; s.position = .middle
        },
        StylePreset(name: "Prism", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.068; s.showBackground = false; s.uppercase = true
            s.wordArt = .prism; s.effect = .popWords; s.position = .middle
        },
        StylePreset(name: "Gradient Pop", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.065; s.showBackground = false; s.uppercase = true
            s.wordArt = .gradient; s.textColor = Color(red: 1.0, green: 0.9, blue: 0.3)
            s.artColor = Color(red: 1.0, green: 0.3, blue: 0.5); s.effect = .pop; s.position = .middle
        },
        StylePreset(name: "Fire", category: .wordArt) { s in
            s.fontName = "Impact"; s.fontScale = 0.072; s.showBackground = false; s.uppercase = true
            s.wordArt = .gradient; s.textColor = Color(red: 1.0, green: 0.92, blue: 0.2)
            s.artColor = Color(red: 1.0, green: 0.25, blue: 0.05); s.effect = .bounce; s.position = .middle
        },
        StylePreset(name: "Delhi", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.068; s.showBackground = false; s.uppercase = true
            s.wordArt = .gradient; s.textColor = Color(red: 1.0, green: 0.6, blue: 0.1)
            s.artColor = Color(red: 0.1, green: 0.65, blue: 0.25); s.effect = .bounce; s.position = .middle
        },
        StylePreset(name: "Comic", category: .wordArt) { s in
            s.fontName = "Avenir Next"; s.fontScale = 0.07; s.showBackground = false; s.uppercase = true
            s.textColor = yellow; s.wordArt = .comic; s.artDepthColor = .black; s.effect = .bounce
            s.position = .middle
        },
        StylePreset(name: "Retro 3D", category: .wordArt) { s in
            s.fontName = "Futura"; s.fontScale = 0.068; s.showBackground = false; s.uppercase = true
            s.textColor = Color(red: 1.0, green: 0.85, blue: 0.3); s.wordArt = .extrude
            s.artDepthColor = Color(red: 0.9, green: 0.3, blue: 0.1); s.effect = .slideUp; s.position = .middle
        },
        StylePreset(name: "Bubble", category: .wordArt) { s in
            s.fontName = "Arial Rounded MT Bold"; s.fontScale = 0.062; s.showBackground = false
            s.wordArt = .bubble; s.artColor = Color(red: 0.2, green: 0.5, blue: 1.0); s.effect = .popWords
            s.position = .middle
        },
        StylePreset(name: "Y2K", category: .wordArt) { s in
            s.fontName = "Arial Rounded MT Bold"; s.fontScale = 0.062; s.showBackground = false
            s.wordArt = .bubble; s.artColor = Color(red: 1.0, green: 0.4, blue: 0.8); s.effect = .popWords
            s.position = .middle
        },
        StylePreset(name: "Sketch", category: .wordArt) { s in
            s.fontName = "Marker Felt"; s.fontScale = 0.065; s.showBackground = false
            s.textColor = Color(red: 1.0, green: 0.95, blue: 0.6); s.wordArt = .outline; s.artColor = .black
            s.effect = .popWords; s.position = .middle
        },

        // Classic & subtitles
        StylePreset(name: "Classic", category: .classic, shortForm: false) { _ in },
        StylePreset(name: "Minimal", category: .classic, shortForm: false) { s in
            s.fontScale = 0.045; s.bold = false; s.showBackground = false
        },
        StylePreset(name: "Subtitle Yellow", category: .classic, shortForm: false) { s in
            s.fontScale = 0.05; s.showBackground = false; s.textColor = Color(red: 1.0, green: 0.92, blue: 0.3)
        },
        StylePreset(name: "Cinematic", category: .classic, shortForm: false) { s in
            s.fontName = "Futura"; s.bold = false; s.fontScale = 0.045; s.showBackground = false
            s.uppercase = true; s.effect = .fade
        },
        StylePreset(name: "Elegant", category: .classic, shortForm: false) { s in
            s.fontName = "Didot"; s.bold = false; s.fontScale = 0.055; s.showBackground = false; s.effect = .fade
        },
        StylePreset(name: "Liquid Glass", category: .classic, shortForm: false) { s in
            s.backgroundColor = .white; s.backgroundOpacity = 0.22; s.effect = .fade
        },
        StylePreset(name: "Podcast", category: .classic, shortForm: false) { s in
            s.backgroundColor = .white; s.backgroundOpacity = 0.92; s.textColor = .black; s.showShadow = false
            s.effect = .fade
        },
        StylePreset(name: "News", category: .classic, shortForm: false) { s in
            s.backgroundColor = Color(red: 0.8, green: 0.1, blue: 0.15); s.backgroundOpacity = 1
            s.uppercase = true; s.effect = .slideUp
        },
        StylePreset(name: "Chalk", category: .classic, shortForm: false) { s in
            s.fontName = "Chalkboard SE"; s.showBackground = false; s.effect = .fade
        },
        StylePreset(name: "Terminal", category: .classic, shortForm: false) { s in
            s.fontName = "Menlo"; s.textColor = green; s.backgroundOpacity = 0.85; s.effect = .typewriter
        },
    ]
}
