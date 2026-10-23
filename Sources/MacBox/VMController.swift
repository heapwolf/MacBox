import AppKit
import Virtualization

enum VMRunState {
    case stopped, installing, starting, running, suspending, stopping
}

struct VMError: LocalizedError {
    var errorDescription: String?
}

final class VMController: NSObject, VZVirtualMachineDelegate {

    /// Every live controller, so running VMs can be suspended before the app quits.
    static let all = NSHashTable<VMController>.weakObjects()

    private weak var document: VMDocument?
    private(set) var virtualMachine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var sharedFolderURLs: [URL] = []

    init(document: VMDocument) {
        self.document = document
        super.init()
        Self.all.add(self)
    }

    private var state: VMRunState {
        get { document?.state ?? .stopped }
        set { document?.state = newValue }
    }

    // MARK: - Installation

    func install(restoreImage url: URL, completion: @escaping () -> Void = {}) {
        state = .installing
        document?.lastError = nil

        VZMacOSRestoreImage.load(from: url) { result in
            DispatchQueue.main.async {
                do {
                    try self.install(try result.get(), completion: completion)
                } catch {
                    self.finishInstall(error: error, completion: completion)
                }
            }
        }
    }

    private func install(_ image: VZMacOSRestoreImage, completion: @escaping () -> Void) throws {
        guard let document = document,
              let requirements = image.mostFeaturefulSupportedConfiguration,
              requirements.hardwareModel.isSupported else {
            throw VMError(errorDescription: "This Mac can't run this version of macOS.")
        }

        document.content.hardwareModel = requirements.hardwareModel.dataRepresentation
        document.content.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
        document.content.cpuCount = max(document.content.cpuCount, requirements.minimumSupportedCPUCount)
        document.content.memorySize = max(document.content.memorySize, requirements.minimumSupportedMemorySize)
        document.discardSavedState()

        // Sparse, so it only takes up the space the guest has written.
        FileManager.default.createFile(atPath: document.diskURL.path, contents: nil)
        let disk = try FileHandle(forWritingTo: document.diskURL)
        try disk.truncate(atOffset: document.content.diskSize << 30)
        try disk.close()

        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: document.auxiliaryStorageURL,
            hardwareModel: requirements.hardwareModel,
            options: .allowOverwrite
        )
        let configuration = try makeConfiguration(auxiliaryStorage: auxiliaryStorage)
        try configuration.validate()

        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm

        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: image.url)
        self.installer = installer
        document.installProgress = installer.progress
        installer.install { result in
            if case .failure(let error) = result {
                self.finishInstall(error: error, completion: completion)
            } else {
                self.document?.content.installed = true
                self.finishInstall(error: nil, completion: completion)
            }
        }
    }

    private func finishInstall(error: Error?, completion: () -> Void) {
        if let error = error {
            report(error)
        }
        installer = nil
        document?.installProgress = nil
        didStop()
        completion()
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .stopped, let document = document else {
            return
        }
        document.lastError = nil

        do {
            let configuration = try makeConfiguration(
                auxiliaryStorage: VZMacAuxiliaryStorage(url: document.auxiliaryStorageURL)
            )
            try configuration.validate()

            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            virtualMachine = vm
            state = .starting

            if document.hasSavedState, (try? configuration.validateSaveRestoreSupport()) != nil {
                vm.restoreMachineStateFrom(url: document.savedStateURL) { error in
                    // Never restore a state twice: the disk moves on as soon as the guest runs.
                    self.document?.discardSavedState()
                    if let error = error {
                        NSLog("Restore failed, booting instead: \(error)")
                        self.didStop()
                        self.start()
                    } else {
                        vm.resume(completionHandler: self.didStart)
                    }
                }
            } else {
                document.discardSavedState()
                vm.start(completionHandler: didStart)
            }
        } catch {
            report(error)
            didStop()
        }
    }

    private func didStart(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            report(error)
            didStop()
        } else {
            state = .running
        }
    }

    /// Presses the guest's power button.
    func requestStop() {
        do {
            try virtualMachine?.requestStop()
        } catch {
            report(error)
        }
    }

    func forceStop(completion: @escaping () -> Void = {}) {
        guard let vm = virtualMachine else {
            return completion()
        }
        state = .stopping
        vm.stop { _ in
            self.didStop()
            completion()
        }
    }

    /// Saves the guest's memory into the package and stops it. The next start resumes from there.
    func suspend(completion: @escaping (Bool) -> Void = { _ in }) {
        guard state == .running, let vm = virtualMachine, let url = document?.savedStateURL else {
            return completion(false)
        }
        state = .suspending

        vm.pause { result in
            if case .failure(let error) = result {
                self.report(error)
                self.state = .running
                return completion(false)
            }
            vm.saveMachineStateTo(url: url) { error in
                if let error = error {
                    self.report(error)
                    try? FileManager.default.removeItem(at: url)
                    vm.resume { _ in self.state = .running }
                    return completion(false)
                }
                vm.stop { _ in
                    self.didStop()
                    completion(true)
                }
            }
        }
    }

    /// For closing the window or quitting, so the guest isn't just powered off.
    func suspendOrStop(completion: @escaping () -> Void) {
        suspend { suspended in
            suspended ? completion() : self.forceStop(completion: completion)
        }
    }

    private func didStop() {
        virtualMachine = nil
        state = .stopped
        sharedFolderURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        sharedFolderURLs = []
    }

    private func report(_ error: Error) {
        NSLog("Error: \(error)")
        document?.lastError = error.localizedDescription
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if state != .installing {
            didStop()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        report(error)
        if state != .installing {
            didStop()
        }
    }

    // MARK: - Configuration

    private func makeConfiguration(auxiliaryStorage: VZMacAuxiliaryStorage) throws -> VZVirtualMachineConfiguration {
        guard let content = document?.content, let diskURL = document?.diskURL,
              let hardwareModel = content.hardwareModel.flatMap(VZMacHardwareModel.init(dataRepresentation:)),
              let machineIdentifier = content.machineIdentifier.flatMap(VZMacMachineIdentifier.init(dataRepresentation:)) else {
            throw VMError(errorDescription: "The virtual machine is missing its hardware model.")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = auxiliaryStorage

        // Only the starting size: the display follows the window from then on.
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2880, heightInPixels: 1800, pixelsPerInch: 220)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress(string: content.macAddress) ?? .randomLocallyAdministered()

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.platform = platform
        configuration.cpuCount = content.cpuCount
        configuration.memorySize = content.memorySize
        configuration.graphicsDevices = [graphics]
        configuration.networkDevices = [network]
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        )]
        configuration.audioDevices = [sound]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.directorySharingDevices = makeSharedFolders(content.sharedFolders)
        return configuration
    }

    /// macOS guests auto-mount these under /Volumes/My Shared Files.
    private func makeSharedFolders(_ folders: [SharedFolder]) -> [VZDirectorySharingDeviceConfiguration] {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource() else {
                NSLog("Skipping shared folder \(folder.name)")
                continue
            }
            sharedFolderURLs.append(url)
            directories[folder.name] = VZSharedDirectory(url: url, readOnly: folder.readOnly)
        }
        guard !directories.isEmpty else {
            return []
        }

        let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return [device]
    }
}
