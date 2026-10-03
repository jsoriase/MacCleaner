import SwiftUI
import AppKit

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        Window("MacCleaner", id: "main") {
            ContentView(engine: engine)
                .environment(\.layoutDirection, appLayoutDirection)
        }
        .defaultSize(width: 1020, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Se vuelve a evaluar cada vez que el motor cambia, asi que se
                // habilita sola despues de la primera limpieza.
                Button(L("menu.history"), action: openHistory)
                    .keyboardShortcut("y")
                    .disabled(!OperationLog.shared.exists)
                Button(L("menu.unignore")) { engine.unignoreAll() }
                    .disabled(engine.ignoredCount == 0 || engine.isScanning || engine.isCleaning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
