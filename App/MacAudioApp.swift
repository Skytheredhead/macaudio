import SwiftUI

@main
struct MacAudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)

        WindowGroup("Plug-In Editor", id: PluginEditorWindow.windowGroupID, for: String.self) { $sessionID in
            PluginEditorWindow(sessionID: sessionID)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentSize)
    }
}
