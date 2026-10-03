import Foundation

/// Which parts of the video survive "remove silences / filler words", and how caption times map onto
/// the shortened video.
struct EditPlan {
    /// Kept ranges of the source video, in seconds, in order.
    let kept: [ClosedRange<Double>]

    static func make(segments: [CaptionSegment], duration: Double, options: EditOptions) -> EditPlan {
        let whole = EditPlan(kept: [0...max(duration, 0.01)])
        guard duration > 0, options.cutsAnything else { return whole }
        let words = segments.flatMap { $0.timedWords() }.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return whole }

        var cuts: [ClosedRange<Double>] = []
        if options.removeFillers {
            for w in words where TextTools.isFiller(w.text) { cuts.append(w.start...w.end) }
        }
        if options.removeSilences {
            let pad = 0.12, threshold = options.silenceThreshold
            let speech = words.filter { !(options.removeFillers && TextTools.isFiller($0.text)) }
            var previousEnd: Double?
            for w in speech {
                let gapStart = previousEnd.map { $0 + pad } ?? 0
                let gap = w.start - (previousEnd ?? 0)
                if gap > threshold, w.start - pad > gapStart { cuts.append(gapStart...(w.start - pad)) }
                previousEnd = max(previousEnd ?? 0, w.end)
            }
            if let end = previousEnd, duration - end > threshold { cuts.append((end + pad)...duration) }
        }

        // Merge overlapping cuts, then keep the complement.
        var merged: [ClosedRange<Double>] = []
        for c in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lo = max(0, c.lowerBound), hi = min(duration, c.upperBound)
            guard hi > lo else { continue }
            if let last = merged.last, lo <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, hi)
            } else {
                merged.append(lo...hi)
            }
        }
        var kept: [ClosedRange<Double>] = []
        var t = 0.0
        for c in merged {
            if c.lowerBound - t > 0.04 { kept.append(t...c.lowerBound) }
            t = c.upperBound
        }
        if duration - t > 0.04 { kept.append(t...duration) }
        return kept.isEmpty ? whole : EditPlan(kept: kept)
    }

    /// Source time → time in the edited video (times inside a cut snap to the cut point).
    func map(_ t: Double) -> Double {
        var out = 0.0
        for r in kept {
            if t <= r.lowerBound { return out }
            if t < r.upperBound { return out + (t - r.lowerBound) }
            out += r.upperBound - r.lowerBound
        }
        return out
    }

    /// Captions re-timed to the edited video; filler words are dropped when they were cut.
    func apply(to segments: [CaptionSegment], dropFillers: Bool) -> [CaptionSegment] {
        segments.compactMap { seg in
            var s = seg
            var words = seg.timedWords()
            var overrides = seg.overrides
            if dropFillers {
                var keptWords: [Word] = []
                var keptOverrides: [Int: WordOverride] = [:]
                for (i, w) in words.enumerated() where !TextTools.isFiller(w.text) {
                    if let o = overrides[i] { keptOverrides[keptWords.count] = o }
                    keptWords.append(w)
                }
                guard !keptWords.isEmpty else { return nil }
                words = keptWords
                overrides = keptOverrides
                s.text = words.map(\.text).joined(separator: " ")
            }
            s.words = words.map { Word(text: $0.text, start: map($0.start), end: map($0.end)) }
            s.overrides = overrides
            s.start = map(seg.start)
            s.end = map(seg.end)
            return s.end > s.start ? s : nil
        }
    }
}
