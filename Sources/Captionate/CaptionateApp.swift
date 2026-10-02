import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CaptionateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Captionate") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { state.openPanel() }
                    .keyboardShortcut("o")
                Button("Import SRT/VTT…") { state.importSubtitles() }
                    .keyboardShortcut("i")
            }
            CommandMenu("Captions") {
                Button("Transcribe") { state.transcribe() }
                    .keyboardShortcut("t")
                    .disabled(state.videoURL == nil || state.isWorking)
                Divider()
                Button("Export Video with Captions…") { state.exportVideo() }
                    .keyboardShortcut("e")
                    .disabled(state.segments.isEmpty || state.isWorking)
                Button("Export SRT…") { state.exportSubtitles(vtt: false) }
                    .disabled(state.segments.isEmpty)
                Button("Export WebVTT…") { state.exportSubtitles(vtt: true) }
                    .disabled(state.segments.isEmpty)
            }
        }
    }
}
