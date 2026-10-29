import Foundation
import SwiftUI

/// One-click format for a platform: canvas, resolution, caption placement inside the platform's safe
/// area, and caption length. The caption *look* (font, colours, effects) is left alone.
struct PlatformTemplate: Identifiable {
    let name: String
    let icon: String
    let note: String
    let aspect: CanvasAspect
    let position: CaptionPosition
    let margin: Double            // fraction of video height, clears the platform's buttons and caption
    let maxWidth: Double
    let fontScale: Double
    let shortForm: Bool
    /// Bands covered by the platform's own UI (fractions of the height), drawn by "Safe zones".
    let topUI: Double
    let bottomUI: Double
    let rightUI: Double

    var id: String { name }

    static let all: [PlatformTemplate] = [
        PlatformTemplate(name: "Reels", icon: "camera", note: "Instagram Reels · 9:16 · 1080p",
                         aspect: .vertical, position: .bottom, margin: 0.26, maxWidth: 0.8, fontScale: 0.042,
                         shortForm: true, topUI: 0.1, bottomUI: 0.2, rightUI: 0.14),
        PlatformTemplate(name: "Shorts", icon: "play.rectangle.on.rectangle", note: "YouTube Shorts · 9:16 · 1080p",
                         aspect: .vertical, position: .bottom, margin: 0.24, maxWidth: 0.8, fontScale: 0.042,
                         shortForm: true, topUI: 0.08, bottomUI: 0.2, rightUI: 0.15),
        PlatformTemplate(name: "TikTok", icon: "music.note", note: "TikTok · 9:16 · 1080p",
                         aspect: .vertical, position: .bottom, margin: 0.28, maxWidth: 0.76, fontScale: 0.04,
                         shortForm: true, topUI: 0.1, bottomUI: 0.24, rightUI: 0.16),
        PlatformTemplate(name: "YouTube", icon: "play.tv", note: "YouTube video · 16:9 · 1080p",
                         aspect: .landscape, position: .bottom, margin: 0.07, maxWidth: 0.85, fontScale: 0.05,
                         shortForm: false, topUI: 0, bottomUI: 0.1, rightUI: 0),
        PlatformTemplate(name: "Square", icon: "square", note: "Feed post · 1:1 · 1080p",
                         aspect: .square, position: .bottom, margin: 0.1, maxWidth: 0.85, fontScale: 0.05,
                         shortForm: true, topUI: 0, bottomUI: 0, rightUI: 0),
    ]

    func apply(style: inout CaptionStyle, edit: inout EditOptions, grouping: inout GroupingOptions) {
        edit.aspect = aspect
        edit.fit = .fill
        edit.resolution = .hd1080
        style.position = position
        style.verticalMargin = margin
        style.maxWidth = maxWidth
        style.fontScale = fontScale
        grouping = shortForm ? .shortForm : .standard
    }
}

/// A saved set of everything: caption look, placement, format, caption length, video look and audio
/// settings. One preset can be the default, applied every time the app opens.
struct UserPreset: Identifiable, Equatable {
    var name: String
    var style: CaptionStyle
    var grouping: GroupingOptions
    var edit: EditOptions

    var id: String { name }
}

/// Saves presets as JSON in Application Support. Missing keys fall back to today's defaults, so presets
/// saved by older versions keep loading when new settings are added.
enum PresetStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captionate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }

    private static let defaultKey = "defaultPresetName"

    static var defaultName: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey) }
    }

    static func load() -> [UserPreset] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String,
                  let style = decode(item["style"], defaults: CaptionStyle()),
                  let grouping = decode(item["grouping"], defaults: GroupingOptions.standard),
                  let edit = decode(item["edit"], defaults: EditOptions()) else { return nil }
            return UserPreset(name: name, style: style, grouping: grouping, edit: edit)
        }
    }

    static func save(_ presets: [UserPreset]) {
        let list: [[String: Any]] = presets.compactMap { p in
            guard let style = object(p.style), let grouping = object(p.grouping), let edit = object(p.edit) else { return nil }
            return ["name": p.name, "style": style, "grouping": grouping, "edit": edit]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func object<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decodes `saved` laid over the encoded defaults, so absent or unknown keys never fail the preset.
    private static func decode<T: Codable>(_ saved: Any?, defaults: T) -> T? {
        guard var merged = object(defaults) else { return nil }
        if let saved = saved as? [String: Any] {
            for (k, v) in saved where merged[k] != nil { merged[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaults
    }
}
