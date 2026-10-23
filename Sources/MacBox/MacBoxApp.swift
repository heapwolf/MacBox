import SwiftUI

@main
struct MacBoxApp: App {

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("MacBox", id: "library") {
            LibraryView()
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup(for: VirtualMachine.ID.self) { $id in
            if let machine = Library.shared.machines.first(where: { $0.id == id }) {
                MachineWindow(machine: machine)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Suspends running VMs before quitting so they come back where they were.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = Library.shared.machines.filter { $0.virtualMachine != nil }
        guard !active.isEmpty else {
            return .terminateNow
        }

        let group = DispatchGroup()
        for machine in active {
            group.enter()
            machine.suspendOrStop { group.leave() }
        }
        group.notify(queue: .main) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
