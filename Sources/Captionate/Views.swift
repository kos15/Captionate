import SwiftUI
import AVKit
import AVFoundation
import QuartzCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if state.videoURL == nil {
                    DropZone()
                } else {
                    PlayerPreview()
                        .background(Color.black)
                    TranscribeBar()
                }
            }
            .frame(minWidth: 560)

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Captions").tag(0)
                    Text("Style").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
                if tab == 0 { CaptionListView() } else { StyleView() }
            }
            .frame(minWidth: 330, idealWidth: 380, maxWidth: 520)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if ["srt", "vtt"].contains(url.pathExtension.lowercased()) {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    state.segments = SubtitleIO.parse(text)
                }
            } else {
                state.load(url)
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button { state.openPanel() } label: { Label("Open", systemImage: "film") }
                Menu {
                    Button("Video with burned-in captions (.mp4)…") { state.exportVideo() }
                    Divider()
                    Button("Subtitles (.srt)…") { state.exportSubtitles(vtt: false) }
                    Button("Subtitles (.vtt)…") { state.exportSubtitles(vtt: true) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(state.segments.isEmpty || state.isWorking)
            }
        }
        .overlay {
            if state.isWorking { WorkingOverlay() }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { state.errorMessage != nil },
                                    set: { if !$0 { state.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

// MARK: - Empty state

struct DropZone: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a video here")
                .font(.title2.weight(.semibold))
            Text("Captions are generated on your Mac — nothing is uploaded.")
                .foregroundStyle(.secondary)
            Button("Open Video…") { state.openPanel() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.tertiary)
                .padding(24)
        )
    }
}

// MARK: - Player + live caption preview

struct PlayerPreview: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            let rect = AVMakeRect(aspectRatio: state.videoSize,
                                  insideRect: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                PlayerView(player: state.player)
                CaptionOverlay(segment: state.activeSegment, time: state.currentTime,
                               style: state.style, size: rect.size)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// AppKit's AVPlayerView wrapped for SwiftUI.
/// (SwiftUI's own `VideoPlayer` crashes in apps built with Swift Package Manager:
/// its `_AVKit_SwiftUI` class metadata fails to load outside an Xcode-built bundle.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Live caption preview, drawn with the same Core Animation layers as the export.
struct CaptionOverlay: NSViewRepresentable {
    let segment: CaptionSegment?
    let time: Double
    let style: CaptionStyle
    let size: CGSize

    func makeNSView(context: Context) -> CaptionLayerView { CaptionLayerView(frame: .zero) }

    func updateNSView(_ view: CaptionLayerView, context: Context) {
        view.render(segment: segment, time: time, style: style, size: size)
    }
}

/// Hosts the export's layers for the active caption. The layer clock is frozen (speed 0) and
/// scrubbed to the playhead, so highlights and animations look exactly as they will in the export.
final class CaptionLayerView: NSView {
    private let clock = CALayer()
    private var builtSegment: CaptionSegment?
    private var builtStyle: CaptionStyle?
    private var builtSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clock.speed = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Bottom-left origin, like the export's render layer.
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func render(segment: CaptionSegment?, time: Double, style: CaptionStyle, size: CGSize) {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if clock.superlayer !== root { root.addSublayer(clock) }
        if segment != builtSegment || style != builtStyle || size != builtSize {
            clock.frame = CGRect(origin: .zero, size: size)
            clock.sublayers?.forEach { $0.removeFromSuperlayer() }
            if let segment, let caption = CaptionLayers.segmentLayer(segment, style: style, renderSize: size) {
                clock.addSublayer(caption)
            }
            builtSegment = segment
            builtStyle = style
            builtSize = size
        }
        clock.timeOffset = time
        CATransaction.commit()
    }
}

// MARK: - Transcribe bar

struct TranscribeBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Picker("Language", selection: $state.locale) {
                ForEach(state.locales, id: \.identifier) { l in
                    Text(Transcriber.displayName(l)).tag(l)
                }
            }
            .frame(maxWidth: 280)

            Button {
                state.transcribe()
            } label: {
                Label(state.segments.isEmpty ? "Generate Captions" : "Re-generate",
                      systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isWorking)

            Spacer()

            Text("\(formatTimestamp(state.currentTime)) / \(formatTimestamp(state.duration))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Progress overlay

struct WorkingOverlay: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(state.statusMessage).font(.headline)
                ProgressView(value: state.progress)
                    .frame(width: 280)
                Text("\(Int(state.progress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") { state.cancelWork() }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Caption list

struct CaptionListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.segments.isEmpty {
                VStack(spacing: 8) {
                    Text("No captions yet").font(.headline)
                    Text("Click Generate Captions, or drop an .srt file.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($state.segments) { $seg in
                        CaptionRow(seg: $seg,
                                   isActive: state.activeSegment?.id == seg.id,
                                   onSeek: { state.seek(to: seg.start) },
                                   onDelete: { state.delete(seg.id) })
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button { state.addCaptionAtPlayhead() } label: {
                    Label("Add at playhead", systemImage: "plus")
                }
                .disabled(state.videoURL == nil)
                Spacer()
                Text("\(state.segments.count) captions").foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }
}

struct CaptionRow: View {
    @Binding var seg: CaptionSegment
    let isActive: Bool
    let onSeek: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onSeek) {
                    Image(systemName: "play.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

                TextField("Start", value: $seg.start, format: .number.precision(.fractionLength(2)))
                    .frame(width: 64)
                Text("→").foregroundStyle(.secondary)
                TextField("End", value: $seg.end, format: .number.precision(.fractionLength(2)))
                    .frame(width: 64)
                Text("s").foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)

            TextField("Caption", text: $seg.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Style

struct StyleView: View {
    @EnvironmentObject var state: AppState
    private let fonts = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section("Presets") {
                HStack {
                    Button("Classic") { state.applyPreset("Classic") }
                    Button("Shorts / Reels") { state.applyPreset("Shorts") }
                    Button("Minimal") { state.applyPreset("Minimal") }
                    Button("Word Box") { state.applyPreset("WordBox") }
                }
                HStack {
                    Button("Typewriter") { state.applyPreset("Typewriter") }
                    Button("Neon") { state.applyPreset("Neon") }
                    Button("Comic") { state.applyPreset("Comic") }
                    Button("Gradient Pop") { state.applyPreset("GradientPop") }
                }
            }

            Section("Text") {
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

            Section("Animation") {
                Picker("Effect", selection: $state.style.effect) {
                    ForEach(CaptionAnimation.allCases) { Text($0.rawValue).tag($0) }
                }
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
                case .extrude, .comic:
                    ColorPicker("Depth colour", selection: $state.style.artDepthColor, supportsOpacity: false)
                case .none:
                    EmptyView()
                }
            }

            Section("Background") {
                Toggle("Background box", isOn: $state.style.showBackground)
                ColorPicker("Box colour", selection: $state.style.backgroundColor, supportsOpacity: false)
                    .disabled(!state.style.showBackground)
                LabeledSlider(label: "Opacity", value: $state.style.backgroundOpacity, range: 0.1...1)
                    .disabled(!state.style.showBackground)
            }

            Section("Layout") {
                Picker("Position", selection: $state.style.position) {
                    ForEach(CaptionPosition.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(label: "Margin", value: $state.style.verticalMargin, range: 0...0.3)
                LabeledSlider(label: "Max width", value: $state.style.maxWidth, range: 0.4...0.98)
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

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range)
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
