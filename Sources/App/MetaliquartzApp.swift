import SwiftUI

@main
struct MetaliquartzApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: CompositionDocument()) { file in
            EditorShellView(document: file.$document)
        }
        .defaultSize(width: 1_280, height: 820)
        .windowStyle(.titleBar)
        .commands {
            MetaliquartzCommands()
        }

        Settings {
            InterfaceSettingsView()
        }
    }
}
