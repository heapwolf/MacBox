import AppKit
import Virtualization

enum RunState: String {
    case stopped, installing, starting, running, suspending, stopping
}

enum RestoreImageSource {
    case latest
    case file(URL)
}

struct VMError: LocalizedError {
    var errorDescription: String?
}

/// One VM: a folder holding config.json, the disk, NVRAM and any saved state.
final class VirtualMachine: NSObject, ObservableObject, Identifiable, VZVirtualMachineDelegate {

    let id: UUID
    let url: URL

    @Published var config: VMConfig {
        didSet { save() }
    }
    @Published private(set) var state = RunState.stopped
    @Published private(set) var installStatus: String?
    @Published private(set) var installProgress: Progress?
    @Published private(set) var virtualMachine: VZVirtualMachine?
    /// Whether this run's configuration supports saving its state; decided at start.
    @Published private(set) var canSuspend = false

    private var installer: VZMacOSInstaller?
    private var accessedURLs: [URL] = []
    private var stopCompletions: [() -> Void] = []

    init(url: URL, config: VMConfig) {
        id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
        self.url = url
        self.config = config
    }

    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var auxiliaryStorageURL: URL { url.appendingPathComponent("aux.img") }
    var efiVariableStoreURL: URL { url.appendingPathComponent("efi.img") }
    var savedStateURL: URL { url.appendingPathComponent("state.vzvmsave") }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    var canStart: Bool {
        state == .stopped && config.installed
    }

    /// A saved state only restores into an identical configuration.
    var canEditSettings: Bool {
        canStart && !hasSavedState
    }

    var statusText: String {
        switch state {
        case .stopped: return hasSavedState ? "Suspended" : "Stopped"
        default: return state.rawValue.capitalized
        }
    }

    func save() {
        do {
            try JSONEncoder().encode(config).write(to: url.appendingPathComponent("config.json"), options: .atomic)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        NSLog("\(config.name): \(error)")
        NSApp.presentError(error)
    }

    // MARK: - Installation

    /// Linux installs itself: boot the ISO and run its installer inside the VM.
    func prepareLinux(installer iso: URL) throws {
        let accessing = iso.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                iso.stopAccessingSecurityScopedResource()
            }
        }
        try createDisk()
        _ = try VZEFIVariableStore(creatingVariableStoreAt: efiVariableStoreURL, options: .allowOverwrite)
        config.installer = try iso.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        config.machineIdentifier = VZGenericMachineIdentifier().dataRepresentation
        config.installed = true
    }

    func ejectInstaller() {
        config.installer = nil
    }

    private func createDisk() throws {
        // Sparse, so it only takes up the space the guest has written.
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let disk = try FileHandle(forWritingTo: diskURL)
        try disk.truncate(atOffset: config.diskSize << 30)
        try disk.close()
    }

    func install(from source: RestoreImageSource) {
        state = .installing

        switch source {
        case .file(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            install(restoreImage: url) {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        case .latest:
            installStatus = "Finding the latest macOS…"
            VZMacOSRestoreImage.fetchLatestSupported { result in
                DispatchQueue.main.async {
                    do {
                        self.download(try result.get())
                    } catch {
                        self.finishInstall(error: error)
                    }
                }
            }
        }
    }

    /// Kept in Caches, so the next VM doesn't download it again.
    private func download(_ image: VZMacOSRestoreImage) {
        let cached = URL.cachesDirectory.appendingPathComponent(image.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: cached.path) {
            return install(restoreImage: cached)
        }

        let version = image.operatingSystemVersion
        installStatus = "Downloading macOS \(version.majorVersion).\(version.minorVersion)…"
        let task = URLSession.shared.downloadTask(with: image.url) { tempURL, response, error in
            // The temporary file is deleted once this returns, so move it now.
            let result = Result {
                guard let tempURL = tempURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw error ?? URLError(.badServerResponse)
                }
                try FileManager.default.moveItem(at: tempURL, to: cached)
            }
            DispatchQueue.main.async {
                do {
                    try result.get()
                    self.install(restoreImage: cached)
                } catch {
                    self.finishInstall(error: error)
                }
            }
        }
        installProgress = task.progress
        task.resume()
    }

    private func install(restoreImage url: URL, completion: @escaping () -> Void = {}) {
        installStatus = "Preparing to install…"
        installProgress = nil

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
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError(errorDescription: "This Mac can't run this version of macOS.")
        }

        config.hardwareModel = requirements.hardwareModel.dataRepresentation
        config.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
        config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
        config.memorySize = max(config.memorySize, requirements.minimumSupportedMemorySize)

        try createDisk()
        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: auxiliaryStorageURL,
            hardwareModel: requirements.hardwareModel,
            options: .allowOverwrite
        )
        let configuration = try makeConfiguration(newAuxiliaryStorage: auxiliaryStorage)
        try configuration.validate()

        let vm = VZVirtualMachine(configuration: configuration)
        vm.delegate = self
        virtualMachine = vm

        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: image.url)
        self.installer = installer
        let version = image.operatingSystemVersion
        installStatus = "Installing macOS \(version.majorVersion).\(version.minorVersion)…"
        installProgress = installer.progress
        installer.install { result in
            if case .failure(let error) = result {
                self.finishInstall(error: error, completion: completion)
            } else {
                self.config.installed = true
                self.finishInstall(error: nil, completion: completion)
            }
        }
    }

    private func finishInstall(error: Error?, completion: () -> Void = {}) {
        installer = nil
        installStatus = nil
        installProgress = nil
        didStop()
        completion()

        if let error = error {
            report(error)
            // A half-installed VM can't boot, so don't leave it in the library.
            Library.shared.delete(self)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard canStart else {
            return
        }

        do {
            let configuration = try makeConfiguration()
            try configuration.validate()

            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            virtualMachine = vm
            canSuspend = (try? configuration.validateSaveRestoreSupport()) != nil
            state = .starting

            if hasSavedState, canSuspend {
                vm.restoreMachineStateFrom(url: savedStateURL) { error in
                    // Never restore a state twice: the disk moves on as soon as the guest runs.
                    try? FileManager.default.removeItem(at: self.savedStateURL)
                    if let error = error {
                        NSLog("Restore failed, booting instead: \(error)")
                        self.didStop()
                        self.start()
                    } else {
                        vm.resume(completionHandler: self.didStart)
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: savedStateURL)
                vm.start(completionHandler: didStart)
            }
        } catch {
            didStop()
            report(error)
        }
    }

    private func didStart(_ result: Result<Void, Error>) {
        if case .failure(let error) = result {
            didStop()
            report(error)
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

    /// Saves the guest's memory and stops it. The next start resumes from there.
    func suspend(completion: @escaping (Bool) -> Void = { _ in }) {
        guard state == .running, canSuspend, let vm = virtualMachine else {
            return completion(false)
        }
        state = .suspending

        vm.pause { result in
            if case .failure(let error) = result {
                self.state = .running
                self.report(error)
                return completion(false)
            }
            vm.saveMachineStateTo(url: self.savedStateURL) { error in
                if let error = error {
                    try? FileManager.default.removeItem(at: self.savedStateURL)
                    vm.resume { _ in self.state = .running }
                    self.report(error)
                    return completion(false)
                }
                vm.stop { _ in
                    self.didStop()
                    completion(true)
                }
            }
        }
    }

    /// For closing the window or quitting, so the guest isn't just powered off. Suspends when the
    /// configuration allows it, and otherwise shuts the guest down cleanly.
    func suspendOrStop(completion: @escaping () -> Void = {}) {
        guard virtualMachine != nil else {
            return completion()
        }
        guard canSuspend else {
            return shutDown(completion: completion)
        }
        suspend { suspended in
            suspended ? completion() : self.shutDown(completion: completion)
        }
    }

    /// Presses the power button, and pulls the plug if the guest hasn't stopped after a minute.
    private func shutDown(completion: @escaping () -> Void) {
        guard let vm = virtualMachine, state == .running else {
            return forceStop(completion: completion)
        }
        stopCompletions.append(completion)
        requestStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if self.virtualMachine === vm {
                self.forceStop()
            }
        }
    }

    private func didStop() {
        virtualMachine = nil
        state = .stopped
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = []
        let completions = stopCompletions
        stopCompletions = []
        completions.forEach { $0() }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if state != .installing {
            didStop()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        if state != .installing {
            didStop()
            report(error)
        }
    }

    // MARK: - Configuration

    private func makeConfiguration(newAuxiliaryStorage: VZMacAuxiliaryStorage? = nil) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memorySize
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        )]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress(string: config.macAddress) ?? .randomLocallyAdministered()
        configuration.networkDevices = [network]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        configuration.audioDevices = [sound]

        switch config.os {
        case .macOS:
            guard let hardwareModel = config.hardwareModel.flatMap(VZMacHardwareModel.init(dataRepresentation:)),
                  let machineIdentifier = config.machineIdentifier.flatMap(VZMacMachineIdentifier.init(dataRepresentation:)) else {
                throw VMError(errorDescription: "\(config.name) is missing its hardware model.")
            }
            let platform = VZMacPlatformConfiguration()
            platform.hardwareModel = hardwareModel
            platform.machineIdentifier = machineIdentifier
            platform.auxiliaryStorage = newAuxiliaryStorage ?? VZMacAuxiliaryStorage(url: auxiliaryStorageURL)
            configuration.platform = platform
            configuration.bootLoader = VZMacOSBootLoader()

            // Only the starting size: the display follows the window from then on.
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2880, heightInPixels: 1800, pixelsPerInch: 220)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZMacKeyboardConfiguration()]
            configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        case .linux:
            guard let machineIdentifier = config.machineIdentifier.flatMap(VZGenericMachineIdentifier.init(dataRepresentation:)) else {
                throw VMError(errorDescription: "\(config.name) is missing its machine identifier.")
            }
            let platform = VZGenericPlatformConfiguration()
            platform.machineIdentifier = machineIdentifier
            configuration.platform = platform
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = VZEFIVariableStore(url: efiVariableStoreURL)
            configuration.bootLoader = bootLoader

            let graphics = VZVirtioGraphicsDeviceConfiguration()
            let width = config.linuxDisplayWidth > 0 ? config.linuxDisplayWidth : 1920
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: width * 10 / 16)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

            if let installer = config.installer {
                let iso = try accessBookmark(installer)
                configuration.storageDevices.append(VZUSBMassStorageDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
                ))
            }

            // Clipboard sharing, for guests running spice-vdagent.
            let console = VZVirtioConsoleDeviceConfiguration()
            let spice = VZVirtioConsolePortConfiguration()
            spice.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            spice.attachment = VZSpiceAgentPortAttachment()
            console.ports[0] = spice
            configuration.consoleDevices = [console]
        }

        configuration.directorySharingDevices = makeSharedFolders()
        if config.os == .linux, config.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosetta = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosetta.share = try VZLinuxRosettaDirectoryShare()
            configuration.directorySharingDevices.append(rosetta)
        }
        return configuration
    }

    /// macOS guests auto-mount these under /Volumes/My Shared Files; Linux guests mount the
    /// "macbox" tag themselves.
    private func makeSharedFolders() -> [VZDirectorySharingDeviceConfiguration] {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in config.sharedFolders {
            do {
                directories[folder.name] = VZSharedDirectory(url: try accessBookmark(folder.bookmark), readOnly: folder.readOnly)
            } catch {
                NSLog("Skipping shared folder \(folder.name): \(error)")
            }
        }
        guard !directories.isEmpty else {
            return []
        }

        let tag = config.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "macbox"
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return [device]
    }

    /// Resolves a security-scoped bookmark and keeps it accessible until the VM stops.
    private func accessBookmark(_ bookmark: Data) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw VMError(errorDescription: "MacBox no longer has access to \(url.lastPathComponent).")
        }
        accessedURLs.append(url)
        return url
    }
}
