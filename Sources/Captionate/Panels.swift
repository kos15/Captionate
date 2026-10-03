import SwiftUI

// MARK: - Sidebar categories

enum SidebarPanel: String, CaseIterable, Identifiable {
    case captions = "Captions"
    case styles = "Styles"
    case text = "Text"
    case effects = "Effects"
    case layout = "Layout"
    case edit = "Edit & Audio"
    case language = "Language"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .captions: return "captions.bubble"
        case .styles: return "square.grid.2x2"
        case .text: return "textformat"
        case .effects: return "wand.and.stars"
        case .layout: return "aspectratio"
        case .edit: return "scissors"
        case .language: return "globe"
        }
    }

    var shortTitle: String { self == .edit ? "Edit" : rawValue }
}

struct PanelTabBar: View {
    @Binding var selection: SidebarPanel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarPanel.allCases) { panel in
                Button { selection = panel } label: {
                    VStack(spacing: 3) {
                        Image(systemName: panel.icon).font(.system(size: 14))
                        Text(panel.shortTitle).font(.system(size: 9.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(selection == panel ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == panel ? Color.accentColor : Color.secondary)
                .help(panel.rawValue)
            }
        }
        .padding(6)
    }
}

// MARK: - Styles (preset library)

struct StylesPanel: View {
    @EnvironmentObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(StylePreset.all.count) styles. Pick one, then fine-tune it in Text, Effects and Layout.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(StylePreset.Category.allCases) { category in
                    Text(category.rawValue).font(.headline)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(StylePreset.all.filter { $0.category == category }) { preset in
                            Button { state.applyPreset(preset) } label: { PresetTile(preset: preset) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct PresetTile: View {
    let preset: StylePreset

    var body: some View {
        let s = preset.style
        VStack(spacing: 6) {
            sample(s)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8))
            Text(preset.name).font(.caption).lineLimit(1)
        }
        .padding(4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func sample(_ s: CaptionStyle) -> some View {
        let word = s.uppercase ? "WORD" : "Word"
        HStack(spacing: 3) {
            if s.heroWord {
                Text(s.uppercase ? "SO" : "so").font(Font(s.nsFont(size: 9) as CTFont)).foregroundStyle(s.textColor)
                Text(word).font(Font(s.heroFont(size: 18) as CTFont)).foregroundStyle(s.heroColor)
            } else {
                Text(s.uppercase ? "THE" : "The")
                    .font(Font(s.nsFont(size: 13) as CTFont))
                    .foregroundStyle(s.textColor)
                Text(word)
                    .font(Font(s.nsFont(size: 13) as CTFont))
                    .foregroundStyle(accentText(s))
                    .padding(.horizontal, s.wordBackground || s.wordArt == .bubble ? 4 : 0)
                    .background(accentBox(s), in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: s.wordArt == .neon ? s.artColor : (s.wordArt == .glow ? s.textColor : .clear), radius: 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(s.showBackground ? s.backgroundColor.opacity(s.backgroundOpacity) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func accentText(_ s: CaptionStyle) -> Color {
        if s.wordHighlight { return s.highlightColor }
        if s.autoEmphasis { return s.emphasisColor }
        if s.wordArt == .gradient { return s.artColor }
        if s.wordArt == .prism { return Color(red: 0.4, green: 0.8, blue: 1.0) }
        return s.textColor
    }

    private func accentBox(_ s: CaptionStyle) -> Color {
        if s.wordBackground { return s.wordBackgroundColor }
        if s.wordArt == .bubble { return s.artColor }
        return .clear
    }
}

// MARK: - Text

struct TextPanel: View {
    @EnvironmentObject var state: AppState
    private let fonts = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section("Font") {
                Picker("Font", selection: $state.style.fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Bold", isOn: $state.style.bold)
                Toggle("UPPERCASE", isOn: $state.style.uppercase)
                LabeledSlider(label: "Size", value: $state.style.fontScale, range: 0.025...0.12)
                ColorPicker("Text colour", selection: $state.style.textColor, supportsOpacity: false)
                Toggle("Shadow", isOn: $state.style.showShadow)
            }

            Section {
                Toggle("One big word per caption", isOn: $state.style.heroWord)
                if state.style.heroWord {
                    Picker("Big word font", selection: $state.style.heroFontName) {
                        ForEach(fonts, id: \.self) { Text($0).tag($0) }
                    }
                    ColorPicker("Big word colour", selection: $state.style.heroColor, supportsOpacity: false)
                    LabeledSlider(label: "Big word size", value: $state.style.heroScale, range: 1.2...2.6)
                    LabeledSlider(label: "Other words", value: $state.style.smallScale, range: 0.4...1.0)
                }
            } header: {
                Text("Big & small")
            } footer: {
                Text("The key word of each caption goes large in its own font on its own line; the rest stay small. Pick the word yourself with Emphasis in the word editor.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Emphasise keywords", isOn: $state.style.autoEmphasis)
                ColorPicker("Keyword colour", selection: $state.style.emphasisColor, supportsOpacity: false)
                LabeledSlider(label: "Keyword size", value: $state.style.emphasisScale, range: 1.0...1.6)
                Toggle("Auto emoji", isOn: $state.style.autoEmoji)
                Toggle("Censor swear words", isOn: $state.style.censorProfanity)
            } header: {
                Text("Keywords & extras")
            } footer: {
                Text("Recolour or emphasise any single word from the Captions tab → word editor.")
                    .foregroundStyle(.secondary)
            }

            Section("Caption box") {
                Toggle("Background box", isOn: $state.style.showBackground)
                ColorPicker("Box colour", selection: $state.style.backgroundColor, supportsOpacity: false)
                    .disabled(!state.style.showBackground)
                LabeledSlider(label: "Opacity", value: $state.style.backgroundOpacity, range: 0.1...1)
                    .disabled(!state.style.showBackground)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Effect", selection: $state.style.effect) {
                    ForEach(CaptionAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Animation")
            } footer: {
                Text("Per-word effects follow the speech timing.").foregroundStyle(.secondary)
            }

            Section("Word art") {
                Picker("Style", selection: $state.style.wordArt) {
                    ForEach(WordArt.allCases) { Text($0.rawValue).tag($0) }
                }
                switch state.style.wordArt {
                case .outline:
                    ColorPicker("Outline colour", selection: $state.style.artColor, supportsOpacity: false)
                case .gradient:
                    ColorPicker("Gradient end colour", selection: $state.style.artColor, supportsOpacity: false)
                case .neon:
                    ColorPicker("Glow colour", selection: $state.style.artColor, supportsOpacity: false)
                case .bubble:
                    ColorPicker("Bubble colour", selection: $state.style.artColor, supportsOpacity: true)
                case .extrude, .comic:
                    ColorPicker("Depth colour", selection: $state.style.artDepthColor, supportsOpacity: false)
                case .none, .glow, .glitch, .prism:
                    EmptyView()
                }
            }

            Section {
                Toggle("Colour the spoken word", isOn: $state.style.wordHighlight)
                ColorPicker("Highlight colour", selection: $state.style.highlightColor, supportsOpacity: false)
                    .disabled(!state.style.wordHighlight)
                Toggle("Box behind the spoken word", isOn: $state.style.wordBackground)
                ColorPicker("Word box colour", selection: $state.style.wordBackgroundColor, supportsOpacity: true)
                    .disabled(!state.style.wordBackground)
            } header: {
                Text("Word-by-word highlight")
            } footer: {
                Text("Text colour and word box work independently — use either one or both.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

struct LayoutPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Caption position") {
                Picker("Position", selection: $state.style.position) {
                    ForEach(CaptionPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(label: "Margin", value: $state.style.verticalMargin, range: 0...0.3)
                LabeledSlider(label: "Max width", value: $state.style.maxWidth, range: 0.4...0.98)
            }

            Section {
                Picker("Aspect ratio", selection: $state.edit.aspect) {
                    ForEach(CanvasAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Framing", selection: $state.edit.fit) {
                    ForEach(CanvasFit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(state.edit.aspect == .original)
                if state.edit.fit == .fit && state.edit.aspect != .original {
                    ColorPicker("Bar colour", selection: $state.edit.canvasColor, supportsOpacity: false)
                }
                Picker("Resolution", selection: $state.edit.resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Format")
            } footer: {
                Text("9:16 for Reels, Shorts and TikTok · 16:9 for YouTube · up to 4K.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Hook title (optional)", text: $state.style.hookText, axis: .vertical)
                    .lineLimit(1...3)
                HStack {
                    Text("Show for")
                    Slider(value: $state.style.hookDuration, in: 1...10, step: 0.5)
                    Text(String(format: "%.1fs", state.style.hookDuration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                ColorPicker("Banner colour", selection: $state.style.hookColor, supportsOpacity: false)
            } header: {
                Text("Hook title")
            } footer: {
                Text("A bold headline at the top for the first seconds — the opening line that stops the scroll.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper("Max characters: \(state.grouping.maxChars)",
                        value: $state.grouping.maxChars, in: 8...80, step: 2)
                Stepper("Max words: \(state.grouping.maxWords)",
                        value: $state.grouping.maxWords, in: 1...20)
                Button("Re-split captions") { state.regroup() }
                    .disabled(state.words.isEmpty)
            } header: {
                Text("Caption length")
            } footer: {
                Text("Re-splitting rebuilds captions from the transcript and discards manual text edits.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Edit & audio

struct EditPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Remove silences & long pauses", isOn: $state.edit.removeSilences)
                HStack {
                    Text("Pause longer than")
                    Slider(value: $state.edit.silenceThreshold, in: 0.3...2.0, step: 0.1)
                    Text(String(format: "%.1fs", state.edit.silenceThreshold))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(!state.edit.removeSilences)
                Toggle("Remove filler words (um, uh…)", isOn: $state.edit.removeFillers)
                Toggle("Auto zoom punch-ins", isOn: $state.edit.autoZoom)
            } header: {
                Text("Smart edit")
            } footer: {
                Text("Cuts and zooms are applied when you export the video; captions are re-timed to match.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up voice (hum & background noise)", isOn: $state.edit.cleanAudio)
                Toggle("Even out loudness", isOn: $state.edit.normalizeLoudness)
            } header: {
                Text("Audio")
            } footer: {
                Text("Processed on your Mac when you export.").foregroundStyle(.secondary)
            }

            Section("Background music") {
                HStack {
                    Text(state.edit.musicURL?.lastPathComponent ?? "No music")
                        .foregroundStyle(state.edit.musicURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if state.edit.musicURL != nil {
                        Button("Remove") { state.edit.musicURL = nil }
                    }
                    Button("Choose…") { state.chooseMusic() }
                }
                LabeledSlider(label: "Music volume", value: $state.edit.musicVolume, range: 0.02...1)
                    .disabled(state.edit.musicURL == nil)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Language

struct LanguagePanel: View {
    @EnvironmentObject var state: AppState
    @State private var script: TextTools.Script = .devanagari

    var body: some View {
        Form {
            Section {
                Picker("Script", selection: $script) {
                    ForEach(TextTools.Script.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Convert captions") { state.convertScript(to: script) }
                    .disabled(state.segments.isEmpty)
            } header: {
                Text("Script")
            } footer: {
                Text("Same words, different alphabet — e.g. Roman Hinglish ↔ हिन्दी. Timings are kept.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if CaptionTranslation.isSupported {
                    Picker("Translate to", selection: $state.translationTarget) {
                        ForEach(CaptionTranslation.targets) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button("Translate captions") { state.requestTranslation() }
                            .disabled(state.segments.isEmpty || state.isTranslating)
                        if state.isTranslating { ProgressView().controlSize(.small) }
                    }
                } else {
                    Text("Translation needs macOS 15 Sequoia or later.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Translate")
            } footer: {
                Text("Uses Apple's on-device translation. macOS may ask to download a language once.")
                    .foregroundStyle(.secondary)
            }

            if state.hasTextBackup {
                Section {
                    Button("Restore original captions") { state.restoreOriginalText() }
                }
            }

            Section {
                Text("Pick the spoken language under the video before generating captions. English (India) handles Hinglish best.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transcription")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Word editor

struct WordChips: View {
    @Binding var seg: CaptionSegment
    @Binding var editingWord: Int?
    let onSplit: (Int) -> Void

    var body: some View {
        let tokens = seg.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        FlowLayout(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                let override = seg.overrides[index]
                Button {
                    if seg.words.count != tokens.count { seg.words = seg.timedWords() }
                    editingWord = index
                } label: {
                    Text(token)
                        .font(.system(size: 11, weight: override?.emphasis == true ? .bold : .regular))
                        .foregroundStyle(override?.color ?? .primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { editingWord == index },
                                              set: { if !$0 { editingWord = nil } })) {
                    WordEditor(seg: $seg, index: index) {
                        editingWord = nil
                        onSplit(index)
                    }
                }
            }
        }
    }
}

struct WordEditor: View {
    @Binding var seg: CaptionSegment
    let index: Int
    let onSplit: () -> Void

    private var tokens: [String] { seg.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    var body: some View {
        Form {
            TextField("Word", text: Binding(
                get: { index < tokens.count ? tokens[index] : "" },
                set: { newValue in
                    let word = newValue.trimmingCharacters(in: .whitespaces)
                    var t = tokens
                    guard index < t.count, !word.isEmpty, !word.contains(" ") else { return }
                    t[index] = word
                    seg.text = t.joined(separator: " ")
                    if index < seg.words.count { seg.words[index].text = word }
                }))
            if index < seg.words.count {
                HStack {
                    TextField("Start", value: $seg.words[index].start, format: .number.precision(.fractionLength(2)))
                    TextField("End", value: $seg.words[index].end, format: .number.precision(.fractionLength(2)))
                    Text("s").foregroundStyle(.secondary)
                }
            }
            Toggle("Custom colour", isOn: Binding(
                get: { seg.overrides[index]?.color != nil },
                set: { on in
                    var o = seg.overrides[index] ?? WordOverride()
                    o.color = on ? Color(red: 1, green: 0.85, blue: 0.1) : nil
                    seg.overrides[index] = o
                }))
            if seg.overrides[index]?.color != nil {
                ColorPicker("Colour", selection: Binding(
                    get: { seg.overrides[index]?.color ?? .white },
                    set: { seg.overrides[index, default: WordOverride()].color = $0 }), supportsOpacity: false)
            }
            Picker("Emphasis", selection: Binding(
                get: { seg.overrides[index]?.emphasis },
                set: { seg.overrides[index, default: WordOverride()].emphasis = $0 })) {
                Text("Automatic").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            Button("Split caption before this word", action: onSplit)
                .disabled(index == 0)
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }
}

/// Wraps its children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
