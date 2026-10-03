import SwiftUI
import AVKit
import AVFoundation
import QuartzCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var panel: SidebarPanel = .captions

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
                PanelTabBar(selection: $panel)
                Divider()
                switch panel {
                case .captions: CaptionListView()
                case .styles: StylesPanel()
                case .text: TextPanel()
                case .effects: EffectsPanel()
                case .layout: LayoutPanel()
                case .edit: EditPanel()
                case .language: LanguagePanel()
                }
            }
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 540)
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
        .captionTranslation(state)
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
            let rect = AVMakeRect(aspectRatio: state.canvasAspect,
                                  insideRect: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Color.black
                PlayerView(player: state.player,
                           gravity: state.edit.fit == .fill ? .resizeAspectFill : .resizeAspect)
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .offset(x: rect.minX, y: rect.minY)
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
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = gravity
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        if view.videoGravity != gravity { view.videoGravity = gravity }
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
            if let hook = CaptionLayers.hookLayer(style: style, renderSize: size) {
                clock.addSublayer(hook)
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
    @State private var showFind = false
    @State private var find = ""
    @State private var replacement = ""
    @State private var matchCase = false
    @State private var findResult = ""

    var body: some View {
        VStack(spacing: 0) {
            if showFind {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Find", text: $find)
                        TextField("Replace with", text: $replacement)
                    }
                    HStack {
                        Toggle("Match case", isOn: $matchCase)
                        Spacer()
                        Text(findResult).foregroundStyle(.secondary).font(.caption)
                        Button("Replace all") {
                            let n = state.findReplace(find, with: replacement, matchCase: matchCase)
                            findResult = n == 1 ? "1 caption changed" : "\(n) captions changed"
                        }
                        .disabled(find.isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(10)
                Divider()
            }
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
                                   onDelete: { state.delete(seg.id) },
                                   onSplit: { index in state.split(seg.id, beforeWord: index) },
                                   onMergeNext: { state.mergeWithNext(seg.id) })
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
                Button { showFind.toggle() } label: {
                    Label("Find & replace", systemImage: "magnifyingglass")
                }
                .disabled(state.segments.isEmpty)
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
    let onSplit: (Int) -> Void
    let onMergeNext: () -> Void
    @State private var showWords = false
    @State private var editingWord: Int?

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
                Button { showWords.toggle() } label: {
                    Image(systemName: showWords ? "textformat.abc.dottedunderline" : "textformat.abc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(showWords ? Color.accentColor : .secondary)
                .help("Edit individual words")
                Menu {
                    Button("Merge with next caption", action: onMergeNext)
                    Button("Delete caption", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)

            TextField("Caption", text: $seg.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)

            if showWords {
                WordChips(seg: $seg, editingWord: $editingWord, onSplit: onSplit)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
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
