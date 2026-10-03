import Foundation
import AppKit
import SwiftUI

/// A single recognised word with timing (seconds, relative to the video start).
struct Word: Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// One on-screen caption.
struct CaptionSegment: Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    /// Recognised word timings. May go stale if the user edits `text`;
    /// `timedWords()` falls back to even spacing in that case.
    var words: [Word] = []

    /// Words of the current text with timings, for word-by-word highlighting.
    func timedWords() -> [Word] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == words.count {
            return zip(tokens, words).map { Word(text: $0, start: $1.start, end: $1.end) }
        }
        let span = max(0.01, end - start) / Double(tokens.count)
        return tokens.enumerated().map { i, t in
            Word(text: t, start: start + Double(i) * span, end: start + Double(i + 1) * span)
        }
    }
}

enum CaptionPosition: String, CaseIterable, Identifiable {
    case bottom = "Bottom"
    case middle = "Middle"
    case top = "Top"
    var id: String { rawValue }
}

/// How a caption (or its words) comes on screen.
enum CaptionAnimation: String, CaseIterable, Identifiable {
    case none = "None"
    case fade = "Fade in"
    case pop = "Pop"
    case slideUp = "Slide up"
    case typewriter = "Typewriter"
    case wordByWord = "Word by word"
    case popWords = "Pop each word"
    case bounce = "Bounce spoken word"
    var id: String { rawValue }
}

/// Decorative text treatments.
enum WordArt: String, CaseIterable, Identifiable {
    case none = "None"
    case outline = "Outline"
    case gradient = "Gradient"
    case neon = "Neon glow"
    case extrude = "3D"
    case comic = "Comic"
    var id: String { rawValue }
}

/// Visual style shared by the live preview and the burned-in export.
/// Sizes are relative to the video height so preview == export.
struct CaptionStyle: Equatable {
    var fontName: String = "Helvetica Neue"
    var bold: Bool = true
    var fontScale: Double = 0.055          // font size as fraction of video height
    var textColor: Color = .white
    var showBackground: Bool = true
    var backgroundColor: Color = .black
    var backgroundOpacity: Double = 0.6
    var showShadow: Bool = true
    var uppercase: Bool = false
    var wordHighlight: Bool = false        // karaoke-style active word colour
    var highlightColor: Color = Color(red: 1.0, green: 0.82, blue: 0.1)
    var wordBackground: Bool = false       // box behind the active word (independent of wordHighlight)
    var wordBackgroundColor: Color = Color(red: 0.49, green: 0.3, blue: 1.0)
    var animation: CaptionAnimation = .none
    var wordArt: WordArt = .none
    var artColor: Color = Color(red: 1.0, green: 0.25, blue: 0.6)      // outline / gradient end / glow
    var artDepthColor: Color = Color(red: 0.1, green: 0.05, blue: 0.3)  // 3D depth / comic outline
    var position: CaptionPosition = .bottom
    var verticalMargin: Double = 0.08      // fraction of video height
    var maxWidth: Double = 0.85            // fraction of video width

    func nsFont(size: CGFloat) -> NSFont {
        let base = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        if bold {
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }

    func displayText(_ s: String) -> String { uppercase ? s.uppercased() : s }
}

/// How words are grouped into captions.
struct GroupingOptions {
    var maxChars: Int = 42
    var maxWords: Int = 12
    var maxDuration: Double = 5.0
    var pauseSplit: Double = 0.7

    static let standard = GroupingOptions()
    static let shortForm = GroupingOptions(maxChars: 20, maxWords: 3, maxDuration: 2.0, pauseSplit: 0.4)
}

extension Color {
    var cgColorValue: CGColor { NSColor(self).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1) }
}

func formatTimestamp(_ t: Double) -> String {
    let total = max(0, t)
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%02d:%05.2f", m, s)
}
