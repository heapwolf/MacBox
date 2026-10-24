import Foundation
import Virtualization

enum GuestOS: String, Codable {
    case macOS, linux
}

struct VMConfig: Codable, Equatable {
    var name: String
    var os = GuestOS.macOS
    var installed = false
    var hardwareModel: Data? // macOS only
    var machineIdentifier: Data?
    /// Bookmark to a Linux installer ISO, attached until it's ejected.
    var installer: Data?
    var macAddress = VZMACAddress.randomLocallyAdministered().string
    var cpuCount = 4
    var memorySize: UInt64 = 8 << 30
    var diskSize: UInt64 = 256 // GB, sparse, and the guest can't grow it later
    var sharedFolders: [SharedFolder] = []
    /// Linux only: lets the guest run x86-64 programs through Rosetta.
    var rosetta = false
    /// Linux only: a fixed 16:10 width the window scales, or 0 to follow the window at full
    /// Retina resolution (for guests set to 200% scaling).
    var linuxDisplayWidth = 1440

    /// Whether the guest's resolution follows the window size.
    var resizesDisplay: Bool {
        os == .macOS || linuxDisplayWidth == 0
    }

    /// Settings added since a VM's config.json was written take their defaults.
    static func decode(_ data: Data) throws -> VMConfig {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VMConfig(name: ""))) as? [String: Any] ?? [:]
        let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let merged = try JSONSerialization.data(withJSONObject: defaults.merging(stored) { $1 })
        return try JSONDecoder().decode(VMConfig.self, from: merged)
    }
}

struct SharedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var readOnly = false
}

/// All VMs, each a `<id>.macbox` folder in the app's Application Support.
final class Library: ObservableObject {

    static let shared = Library()

    @Published private(set) var machines: [VirtualMachine] = []

    private let directory = URL.applicationSupportDirectory.appendingPathComponent("VMs")

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "macbox" {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
                  let config = try? VMConfig.decode(data) else {
                continue
            }
            if config.installed {
                machines.append(VirtualMachine(url: url, config: config))
            } else {
                // An install that never finished can't boot.
                try? FileManager.default.removeItem(at: url)
            }
        }
        machines.sort { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
    }

    func create(_ config: VMConfig) throws -> VirtualMachine {
        let url = directory.appendingPathComponent("\(UUID().uuidString).macbox")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let machine = VirtualMachine(url: url, config: config)
        machine.save()
        machines.append(machine)
        return machine
    }

    func delete(_ machine: VirtualMachine) {
        try? FileManager.default.removeItem(at: machine.url)
        machines.removeAll { $0 === machine }
    }
}
