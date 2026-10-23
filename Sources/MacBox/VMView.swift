import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct VMView: View {

    @ObservedObject var document: VMDocument

    var body: some View {
        Group {
            if document.fileURL == nil {
                VMCreateView(document: document)
            } else if !document.content.installed {
                VMInstallView(document: document)
            } else if let vm = document.controller.virtualMachine {
                VMDisplayView(virtualMachine: vm)
            } else {
                VMStoppedView(document: document)
            }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .navigationSubtitle(document.content.installed ? document.statusText : "")
        .toolbar { VMToolbar(document: document) }
        .windowToolbarFullScreenVisibility(.onHover)
        .focusedSceneObject(document)
        .sheet(isPresented: $document.isShowingSettings) {
            VMSettingsView(document: document)
        }
        .onChange(of: document.content) { document.writeMetadata() }
        // Closing the window shouldn't pull the plug on the guest.
        .onDisappear { document.controller.suspendOrStop {} }
    }
}

struct VMDisplayView: NSViewRepresentable {

    var virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = virtualMachine
    }
}

/// Play/pause/power buttons, as in UTM's VM windows.
struct VMToolbar: ToolbarContent {

    @ObservedObject var document: VMDocument

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if document.state == .running {
                Button("Suspend", systemImage: "pause.fill") {
                    document.controller.suspend()
                }
                Menu {
                    Button("Force Stop") { document.controller.forceStop() }
                } label: {
                    Label("Shut Down", systemImage: "power")
                } primaryAction: {
                    document.controller.requestStop()
                }
            } else {
                Button(document.hasSavedState ? "Resume" : "Start", systemImage: "play.fill") {
                    document.controller.start()
                }
                .disabled(!document.canStart)
            }
            Button("Settings", systemImage: "slider.horizontal.3") {
                document.isShowingSettings = true
            }
            .disabled(!document.canEditSettings)
        }
    }
}

/// UTM's detail pane: a big play button over a summary of the machine.
struct VMStoppedView: View {

    @ObservedObject var document: VMDocument

    var body: some View {
        VStack(spacing: 24) {
            Button {
                document.controller.start()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!document.canStart)

            Text(document.name)
                .font(.title)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                row("Status", document.statusText)
                row("CPU", "\(document.content.cpuCount) Cores")
                row("Memory", ByteCountFormatter.string(fromByteCount: Int64(document.content.memorySize), countStyle: .memory))
                row("Size", ByteCountFormatter.string(fromByteCount: Int64(diskUsage), countStyle: .file))
                row("Shared Folders", document.content.sharedFolders.isEmpty ? "None" : document.content.sharedFolders.map(\.name).joined(separator: ", "))
            }
            .padding()
            .frame(width: 360)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            ErrorText(document: document)
        }
    }

    /// Space the sparse disk actually takes up, which is what UTM's "Size" shows.
    private var diskUsage: Int {
        (try? document.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct VMCreateView: View {

    @ObservedObject var document: VMDocument

    var body: some View {
        Form {
            VMHardwareFields(content: $document.content)
            TextField("Disk Size (GB)", value: $document.content.diskSize, format: .number)
            Button("Continue…") {
                NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }
}

struct VMInstallView: View {

    @ObservedObject var document: VMDocument

    @State private var status: String?
    @State private var progress: Progress?
    @State private var isChoosingRestoreImage = false

    var body: some View {
        VStack(spacing: 16) {
            if document.state == .installing {
                Text("Installing macOS…")
                ProgressView(document.installProgress ?? Progress())
            } else if let status = status {
                Text(status)
                ProgressView(progress ?? Progress())
            } else {
                Text("Install macOS")
                    .font(.title)
                HStack(spacing: 16) {
                    card("Download", systemImage: "arrow.down.circle", detail: "The latest macOS this Mac supports", action: downloadLatest)
                    card("Restore Image", systemImage: "doc.badge.gearshape", detail: "An .ipsw file you already have") {
                        isChoosingRestoreImage = true
                    }
                }
            }
            ErrorText(document: document)
        }
        .frame(maxWidth: 480)
        // Name Apple's type explicitly: another app declaring .ipsw can win the extension lookup.
        .fileImporter(isPresented: $isChoosingRestoreImage, allowedContentTypes: [UTType("com.apple.itunes.ipsw"), UTType(filenameExtension: "ipsw")].compactMap { $0 }) { result in
            guard let url = try? result.get() else {
                return
            }
            _ = url.startAccessingSecurityScopedResource()
            document.controller.install(restoreImage: url) {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// A big icon tile, like UTM's new-VM wizard.
    private func card(_ title: String, systemImage: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, height: 140)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Downloads the newest macOS this Mac supports, keeping it in Caches for the next VM.
    private func downloadLatest() {
        status = "Finding the latest macOS…"
        VZMacOSRestoreImage.fetchLatestSupported { result in
            DispatchQueue.main.async {
                guard let image = try? result.get() else {
                    return finish(result.map(\.url))
                }
                let cached = URL.cachesDirectory.appendingPathComponent(image.url.lastPathComponent)
                if FileManager.default.fileExists(atPath: cached.path) {
                    return finish(.success(cached))
                }

                status = "Downloading macOS \(image.operatingSystemVersion.majorVersion)…"
                let task = URLSession.shared.downloadTask(with: image.url) { tempURL, response, error in
                    // The temporary file is deleted once this returns, so move it now.
                    let result = Result {
                        guard let tempURL = tempURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw error ?? URLError(.badServerResponse)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: cached)
                        return cached
                    }
                    DispatchQueue.main.async { finish(result) }
                }
                progress = task.progress
                task.resume()
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        status = nil
        progress = nil
        switch result {
        case .success(let url):
            document.controller.install(restoreImage: url)
        case .failure(let error):
            document.lastError = error.localizedDescription
        }
    }
}

struct VMSettingsView: View {

    @ObservedObject var document: VMDocument
    @Environment(\.dismiss) private var dismiss
    @State private var isAddingFolder = false

    var body: some View {
        Form {
            VMHardwareFields(content: $document.content)
            Section("Shared Folders (/Volumes/My Shared Files)") {
                ForEach($document.content.sharedFolders) { $folder in
                    HStack {
                        Text(folder.name)
                        Spacer()
                        Toggle("Read Only", isOn: $folder.readOnly)
                        Button("Remove") {
                            document.content.sharedFolders.removeAll { $0.id == folder.id }
                        }
                    }
                }
                Button("Add Folder…") {
                    isAddingFolder = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 400)
        .toolbar {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .fileImporter(isPresented: $isAddingFolder, allowedContentTypes: [.folder]) { result in
            guard let url = try? result.get() else {
                return
            }
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                document.content.sharedFolders.append(SharedFolder(name: url.lastPathComponent, bookmark: bookmark))
            }
        }
    }
}

struct VMHardwareFields: View {

    @Binding var content: VMContent

    var body: some View {
        Picker("CPU Cores", selection: $content.cpuCount) {
            ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { Text("\($0)") }
        }
        Picker("Memory", selection: $content.memorySize) {
            ForEach(Array(stride(from: UInt64(2), through: ProcessInfo.processInfo.physicalMemory >> 30, by: 2)), id: \.self) {
                Text("\($0) GB").tag($0 << 30)
            }
        }
    }
}

struct ErrorText: View {

    @ObservedObject var document: VMDocument

    var body: some View {
        if let error = document.lastError {
            Text(error)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }
}
