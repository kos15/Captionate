import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// A request to translate every caption (source language is detected automatically).
struct TranslationRequest: Equatable {
    let id = UUID()
    let target: Locale.Language
}

enum CaptionTranslation {
    /// Apple's on-device Translation framework (macOS 15+). Language packs download once, then work offline.
    static var isSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    struct Target: Identifiable {
        let name: String
        let id: String
        init(_ name: String, _ id: String) { self.name = name; self.id = id }
    }

    static let targets: [Target] = [
        Target("English", "en"), Target("Hindi", "hi"), Target("Spanish", "es"), Target("French", "fr"), Target("German", "de"),
        Target("Italian", "it"), Target("Portuguese (Brazil)", "pt-BR"), Target("Japanese", "ja"), Target("Korean", "ko"),
        Target("Chinese (Simplified)", "zh-Hans"), Target("Chinese (Traditional)", "zh-Hant"), Target("Arabic", "ar"),
        Target("Russian", "ru"), Target("Turkish", "tr"), Target("Indonesian", "id"), Target("Thai", "th"), Target("Vietnamese", "vi"),
        Target("Ukrainian", "uk"), Target("Polish", "pl"), Target("Dutch", "nl"),
    ]
}

extension View {
    /// Runs caption translations requested through `AppState.requestTranslation(to:)`.
    @ViewBuilder func captionTranslation(_ state: AppState) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            modifier(TranslationRunner(state: state))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TranslationRunner: ViewModifier {
    @ObservedObject var state: AppState
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: state.translationRequest) { _, request in
                guard let request else { return }
                if configuration?.target == request.target {
                    configuration?.invalidate()   // same language again: re-run
                } else {
                    configuration = TranslationSession.Configuration(source: nil, target: request.target)
                }
            }
            .translationTask(configuration) { session in
                await translate(with: session)
            }
    }

    @MainActor
    private func translate(with session: TranslationSession) async {
        let segments = state.segments
        guard !segments.isEmpty else { return }
        state.isTranslating = true
        defer { state.isTranslating = false }
        do {
            let requests = segments.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
            }
            let responses = try await session.translations(from: requests)
            var byID: [String: String] = [:]
            for response in responses {
                if let id = response.clientIdentifier { byID[id] = response.targetText }
            }
            state.applyTranslation(byID)
        } catch {
            state.errorMessage = "Translation failed: \(error.localizedDescription)"
        }
    }
}
#endif
