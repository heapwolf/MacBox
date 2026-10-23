import SwiftUI

@main
struct MacBoxApp: App {

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { VMDocument() }) { configuration in
            // Set before any view reads it; it changes when the document is saved or moved.
            configuration.document.fileURL = configuration.fileURL
            return VMView(document: configuration.document)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            VMCommands()
        }
    }
}

/// Acts on the VM in the key window.
struct VMCommands: Commands {

    @FocusedObject private var document: VMDocument?

    var body: some Commands {
        CommandMenu("Virtual Machine") {
            let running = document?.state == .running

            Button(document?.hasSavedState == true ? "Resume" : "Start") { document?.controller.start() }
                .disabled(document?.canStart != true)
            Button("Suspend") { document?.controller.suspend() }
                .disabled(!running)
            Divider()
            Button("Shut Down") { document?.controller.requestStop() }
                .disabled(!running)
            Button("Force Stop") { document?.controller.forceStop() }
                .disabled(!running)
            Divider()
            Button("Settings…") { document?.isShowingSettings = true }
                .disabled(document?.canEditSettings != true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Suspends running VMs before quitting so they come back where they were.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = VMController.all.allObjects.filter { $0.virtualMachine != nil }
        guard !active.isEmpty else {
            return .terminateNow
        }

        let group = DispatchGroup()
        for controller in active {
            group.enter()
            controller.suspendOrStop { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
