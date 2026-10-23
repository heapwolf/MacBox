import SwiftUI
import UniformTypeIdentifiers
import Virtualization

extension UTType {
    static let macBoxVM = UTType(exportedAs: "com.heapwolf.macbox.vm")
}

struct VMContent: Codable, Equatable {
    var installed = false
    var hardwareModel: Data?
    var machineIdentifier: Data?
    var macAddress = VZMACAddress.randomLocallyAdministered().string
    var cpuCount = 4
    var memorySize: UInt64 = 8 << 30
    var diskSize: UInt64 = 64 // GB
    var sharedFolders: [SharedFolder] = []
}

struct SharedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var readOnly = false
}

/// A `.macbox` package: JSON metadata next to the disk, NVRAM and saved state that
/// Virtualization.framework reads and writes directly.
final class VMDocument: ReferenceFileDocument {

    static let readableContentTypes: [UTType] = [.macBoxVM]

    @Published var content = VMContent()
    @Published var state: VMRunState = .stopped
    @Published var installProgress: Progress?
    @Published var lastError: String?
    @Published var isShowingSettings = false

    /// Nil until a new document is first saved.
    var fileURL: URL?
    private(set) lazy var controller = VMController(document: self)

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let metadata = configuration.file.fileWrappers?["metadata"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        content = try JSONDecoder().decode(VMContent.self, from: metadata)
    }

    func snapshot(contentType: UTType) throws -> VMContent {
        content
    }

    func fileWrapper(snapshot: VMContent, configuration: WriteConfiguration) throws -> FileWrapper {
        var children = ["metadata": FileWrapper(regularFileWithContents: try JSONEncoder().encode(snapshot))]
        // Only the first save and Duplicate/Save As come through here. Copy the VM files from
        // disk; unread file wrappers are hard-linked rather than copied.
        for name in ["disk.img", "aux.img", "state.vzvmsave"] {
            if let url = fileURL?.appendingPathComponent(name), let wrapper = try? FileWrapper(url: url) {
                children[name] = wrapper
            }
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    var diskURL: URL { fileURL!.appendingPathComponent("disk.img") }
    var auxiliaryStorageURL: URL { fileURL!.appendingPathComponent("aux.img") }
    var savedStateURL: URL { fileURL!.appendingPathComponent("state.vzvmsave") }

    var hasSavedState: Bool {
        fileURL != nil && FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    var name: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "New Virtual Machine"
    }

    var statusText: String {
        state == .stopped && hasSavedState ? "Suspended" : "\(state)".capitalized
    }

    var canStart: Bool {
        state == .stopped && content.installed
    }

    /// A saved state only restores into an identical configuration.
    var canEditSettings: Bool {
        canStart && !hasSavedState
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    /// Once the package exists it's never saved through NSDocument, which would rewrite it while
    /// the VM is writing its disk. The document stays clean and metadata goes straight to disk.
    func writeMetadata() {
        guard let fileURL = fileURL else {
            return
        }
        do {
            try JSONEncoder().encode(content).write(to: fileURL.appendingPathComponent("metadata"), options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
