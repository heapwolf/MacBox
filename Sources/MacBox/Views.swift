import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct LibraryView: View {

    @ObservedObject private var library = Library.shared
    @State private var selection: VirtualMachine.ID?
    @State private var isCreating = false

    var body: some View {
        NavigationSplitView {
            List(library.machines, selection: $selection) { machine in
                MachineRow(machine: machine)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Virtual Machine", systemImage: "plus") { isCreating = true }
            }
        } detail: {
            if let machine = library.machines.first(where: { $0.id == selection }) {
                MachineDetailView(machine: machine)
            } else {
                ContentUnavailableView {
                    Label("No Virtual Machine Selected", systemImage: "apple.logo")
                } actions: {
                    Button("New Virtual Machine…") { isCreating = true }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            NewMachineView { selection = $0.id }
        }
        .onAppear { selection = library.machines.first?.id }
    }
}

struct MachineRow: View {

    @ObservedObject var machine: VirtualMachine

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(machine.config.name)
                Text(machine.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: machine.config.os == .macOS ? "apple.logo" : "terminal")
        }
    }
}

struct MachineDetailView: View {

    @ObservedObject var machine: VirtualMachine
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingSettings = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 24) {
            if machine.state == .installing {
                Text(machine.installStatus ?? "Installing macOS…")
                    .font(.title2)
                if let progress = machine.installProgress {
                    ProgressView(progress)
                        .frame(width: 360)
                } else {
                    ProgressView()
                }
                Text("This can take a while.")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    machine.start()
                    openWindow(value: machine.id)
                } label: {
                    Image(systemName: machine.state == .stopped ? "play.circle.fill" : "macwindow")
                        .font(.system(size: 96))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(machine.state == .stopped ? "Start" : "Show Window")
                .disabled(!machine.canStart && machine.state != .running)

                Text(machine.config.name)
                    .font(.title)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Status", machine.statusText)
                    row("OS", machine.config.os == .macOS ? "macOS" : "Linux")
                    row("CPU", "\(machine.config.cpuCount) Cores")
                    row("Memory", ByteCountFormatter.string(fromByteCount: Int64(machine.config.memorySize), countStyle: .memory))
                    row("Disk", "\(diskUsage) of \(machine.config.diskSize) GB used")
                    row("Shared Folders", machine.config.sharedFolders.isEmpty ? "None" : machine.config.sharedFolders.map(\.name).joined(separator: ", "))
                }
                .padding()
                .frame(width: 380)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    if machine.config.installer != nil {
                        Button("Eject Installer") { machine.ejectInstaller() }
                            .disabled(machine.state != .stopped)
                    }
                    Button("Settings…") { isShowingSettings = true }
                        .disabled(!machine.canEditSettings)
                    Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                        .disabled(machine.state != .stopped)
                }
                if machine.config.installer != nil {
                    Text("The installer ISO is attached. Eject it once Linux is installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if machine.hasSavedState && machine.state == .stopped {
                    Text("Settings are locked while the virtual machine is suspended.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(machine: machine)
        }
        .confirmationDialog("Delete \(machine.config.name)?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { Library.shared.delete(machine) }
        } message: {
            Text("Its disk is deleted too. This can't be undone.")
        }
    }

    /// The disk is sparse, so this is the space it actually takes up.
    private var diskUsage: String {
        let bytes = (try? machine.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct NewMachineView: View {

    var onCreate: (VirtualMachine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config = VMConfig(name: "macOS")
    @State private var source = RestoreImageSource.latest
    @State private var linuxInstaller: URL?
    @State private var isChoosingFile = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Operating System", selection: $config.os) {
                    Text("macOS").tag(GuestOS.macOS)
                    Text("Linux").tag(GuestOS.linux)
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $config.name)

                if config.os == .macOS {
                    Section("macOS") {
                        LabeledContent("Install from") {
                            if case .file(let url) = source {
                                Text(url.lastPathComponent)
                            } else {
                                Text("Latest version (downloaded)")
                            }
                        }
                        HStack {
                            Button("Choose .ipsw File…") { isChoosingFile = true }
                            if case .file = source {
                                Button("Download Latest Instead") { source = .latest }
                            }
                        }
                    }
                } else {
                    Section("Linux") {
                        LabeledContent("Installer") {
                            Text(linuxInstaller?.lastPathComponent ?? "None")
                        }
                        Button("Choose .iso File…") { isChoosingFile = true }
                        Note("Use an ARM64 (aarch64) installer. The VM boots it, and you install Linux from there.")
                    }
                }
                Section("Hardware") {
                    HardwareFields(config: $config)
                    Picker("Disk Size", selection: $config.diskSize) {
                        ForEach([64, 128, 256, 512, 1024] as [UInt64], id: \.self) { Text(verbatim: "\($0) GB") }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || (config.os == .linux && linuxInstaller == nil))
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onChange(of: config.os) {
            if config.name == "macOS" || config.name == "Linux" {
                config.name = config.os == .macOS ? "macOS" : "Linux"
            }
        }
        // One importer for both: SwiftUI only presents one per view. Name Apple's .ipsw type
        // explicitly, since another app declaring the extension can win the lookup.
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: config.os == .macOS
            ? [UTType("com.apple.itunes.ipsw"), UTType(filenameExtension: "ipsw")].compactMap { $0 }
            : [.diskImage]
        ) { result in
            guard let url = try? result.get() else {
                return
            }
            if config.os == .macOS {
                source = .file(url)
            } else {
                linuxInstaller = url
            }
        }
    }

    private func create() {
        do {
            let machine = try Library.shared.create(config)
            if config.os == .macOS {
                machine.install(from: source)
            } else if let linuxInstaller = linuxInstaller {
                do {
                    try machine.prepareLinux(installer: linuxInstaller)
                } catch {
                    Library.shared.delete(machine)
                    throw error
                }
            }
            onCreate(machine)
            dismiss()
        } catch {
            NSApp.presentError(error)
        }
    }
}

struct SettingsView: View {

    @ObservedObject var machine: VirtualMachine
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $machine.config.name)
                Section("Hardware") {
                    HardwareFields(config: $machine.config)
                }
                Section(machine.config.os == .macOS
                    ? "Shared Folders (/Volumes/My Shared Files)"
                    : "Shared Folders (mount -t virtiofs macbox /mnt)"
                ) {
                    ForEach($machine.config.sharedFolders) { $folder in
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Toggle("Read Only", isOn: $folder.readOnly)
                            Button("Remove") {
                                machine.config.sharedFolders.removeAll { $0.id == folder.id }
                            }
                        }
                    }
                    Button("Add Folder…") { isAddingFolder = true }
                }
                if machine.config.os == .linux {
                    Section("Display") {
                        Picker("Resolution", selection: $machine.config.linuxDisplayWidth) {
                            ForEach([1280, 1440, 1680, 1920, 2560], id: \.self) { Text(verbatim: "\($0) × \($0 * 10 / 16)") }
                            Text("Fit Window (Retina)").tag(0)
                        }
                        Note("Fit Window uses every Retina pixel, so set the guest's display scaling to 200% first.")
                    }
                    Section("Rosetta") {
                        Toggle("Run x86-64 programs with Rosetta", isOn: $machine.config.rosetta)
                            .disabled(VZLinuxRosettaDirectoryShare.availability == .notSupported)
                        Note("In the guest, mount it with mount -t virtiofs rosetta /media/rosetta and register it with binfmt. See the README.")
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: machine.config.rosetta) {
                // Rosetta is an optional macOS component; offer to install it the first time.
                if machine.config.rosetta, VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                    VZLinuxRosettaDirectoryShare.installRosetta { error in
                        DispatchQueue.main.async {
                            if let error = error {
                                machine.config.rosetta = false
                                NSApp.presentError(error)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: machine.config.os == .linux ? 640 : 440)
        .fileImporter(isPresented: $isAddingFolder, allowedContentTypes: [.folder]) { result in
            guard let url = try? result.get() else {
                return
            }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                machine.config.sharedFolders.append(SharedFolder(name: url.lastPathComponent, bookmark: bookmark))
            }
        }
    }
}

struct HardwareFields: View {

    @Binding var config: VMConfig

    var body: some View {
        Picker("CPU Cores", selection: $config.cpuCount) {
            ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { Text("\($0)") }
        }
        Picker("Memory", selection: $config.memorySize) {
            ForEach(Array(stride(from: UInt64(2), through: ProcessInfo.processInfo.physicalMemory >> 30, by: 2)), id: \.self) {
                Text("\($0) GB").tag($0 << 30)
            }
        }
    }
}

/// A running VM's screen, in its own window like UTM.
struct MachineWindow: View {

    @ObservedObject var machine: VirtualMachine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let vm = machine.virtualMachine {
                DisplayView(virtualMachine: vm, resizesDisplay: machine.config.resizesDisplay)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(machine.config.name)
        .navigationSubtitle(machine.statusText)
        .toolbar {
            Button("Suspend", systemImage: "pause.fill") { machine.suspend() }
                .disabled(machine.state != .running || !machine.canSuspend)
            Menu {
                Button("Force Stop") { machine.forceStop() }
            } label: {
                Label("Shut Down", systemImage: "power")
            } primaryAction: {
                machine.requestStop()
            }
            .disabled(machine.state != .running)
        }
        .windowToolbarFullScreenVisibility(.onHover)
        .onChange(of: machine.state) {
            if machine.state == .stopped {
                dismiss()
            }
        }
        // Closing the window suspends the guest rather than pulling the plug.
        .onDisappear { machine.suspendOrStop() }
    }
}

struct DisplayView: NSViewRepresentable {

    var virtualMachine: VZVirtualMachine
    var resizesDisplay: Bool

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
        view.automaticallyReconfiguresDisplay = resizesDisplay
    }
}

/// Explanatory text as a form row: section footers only get half the sheet's width.
struct Note: View {

    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
