//
//  VMInstallView.swift
//  MacVM
//
//  Created by Khaos Tian on 6/28/21.
//

import SwiftUI
import UniformTypeIdentifiers

struct VMInstallView: View {
    
    var fileURL: URL?
    var document: VMDocument
    
    @Environment(\.undoManager) var undoManager
    @ObservedObject var state: VMInstallationState
        
    @State var cpuCount: Int = 2
    @State var memorySize: Int = 2
    @State var diskSize: String = "32"
    @State var os: String = "Montery"
    
    @State var presentFileSelector = false
    @State var skipInstallation = false
    @State var ipswURL: URL?
    
    let availableMemoryOptions: [Int] = {
        let baseUnit = 1024 * 1024 * 1024 // GB
        let availableMemory = Int(ProcessInfo.processInfo.physicalMemory)
        
        var availableOptions: [Int] = []
        var memorySize = 2
        
        while memorySize * baseUnit <= availableMemory {
            availableOptions.append(memorySize)
            memorySize += 2
        }
        
        return availableOptions
    }()

    func download (os: String, completion: @escaping (URL?, Error?) -> Void) {
        var url: URL

        switch (os) {
            case "Montery":
                url = URL(string: "https://updates.cdn-apple.com/2021FCSFall/fullrestores/002-23780/D3417F21-41BD-4DDF-9135-FA5A129AF6AF/UniversalMac_12.0.1_21A559_Restore.ipsw")!
                break
            case "Big Sur":
                url = URL(string: "https://updates.cdn-apple.com/2021FallFCS/fullrestores/071-97388/C361BF5E-0E01-47E5-8D30-5990BC3C9E29/UniversalMac_11.6_20G165_Restore.ipsw")!
                break
            case "Ubuntu":
                url = URL(string: "https://releases.ubuntu.com/21.10/ubuntu-21.10-desktop-amd64.iso")!
                break
            default:
            return
        }

        let task = URLSession.shared.downloadTask(with: url) {
            (tempURL, response, error) in
            completion(tempURL, nil)
        }

        task.resume()
    }

    var body: some View {
        if let fileURL = fileURL {
            if let ipswURL = ipswURL {
                VStack {
                    if state.isInstalling, let progress = state.progress {
                        ProgressView(progress)
                    } else {
                        Button("Install") {
                            document.createVMInstance(with: fileURL)
                            document.vmInstance?.diskImageSize = document.content.diskSize
                            document.vmInstance?.startInstaller(
                                with: ipswURL,
                                skipActualInstallation: skipInstallation,
                                completion: { _ in
                                    save()
                                }
                            )
                        }
                        .disabled(state.isInstalling)
                    }
                }
                .padding()
            } else {
                VStack {
                    Picker("Operating System", selection: $os) {
                        Text("Montery")
                        Text("Big Sur")
                        Text("Ubuntu")
                    }
                    Button("Download") {
                        download(os: "Montery") { fileURL, err in
                            if (err != nil) {
                                return
                            }
                            
                            document.createVMInstance(with: fileURL!)
                            document.vmInstance?.diskImageSize = document.content.diskSize
                            document.vmInstance?.startInstaller(
                                with: fileURL!,
                                skipActualInstallation: skipInstallation,
                                completion: { _ in
                                    save()
                                }
                            )
                        }
                    }
                    
                    Button("Select IPSW") {
                        presentFileSelector = true
                    }.fileImporter(
                        isPresented: $presentFileSelector,
                        allowedContentTypes: [
                            UTType(filenameExtension: "ipsw") ?? .data
                        ],
                        onCompletion: { result in
                            switch result {
                            case .success(let url):
                                ipswURL = url
                                if skipInstallation {
                                    document.createVMInstance(with: fileURL)
                                    document.vmInstance?.diskImageSize = document.content.diskSize
                                    document.vmInstance?.startInstaller(
                                        with: url,
                                        skipActualInstallation: skipInstallation,
                                        completion: { _ in
                                            save()
                                        }
                                    )
                                }
                            case .failure(let error):
                                print(error)
                            }
                        }
                    )
                }
                .padding()
            }
        } else {
            Form {
                Section {
                    Picker("CPU Count", selection: $cpuCount) {
                        ForEach(1...ProcessInfo.processInfo.processorCount, id: \.self) { count in
                            Text("\(count)")
                        }
                    }
                    Picker("Memory Size", selection: $memorySize) {
                        ForEach(availableMemoryOptions, id: \.self) { size in
                            Text("\(size) GB")
                        }
                    }
                    TextField("Disk Size (GB)", text: $diskSize)
                }
                
                Section {
                    Button("Continue", action: {
                        NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                    })
                }
            }
            .padding(150)
            .frame(minWidth: 750, idealWidth: 600, minHeight: 450, idealHeight: 800)
            .onChange(of: cpuCount) { newValue in
                document.content.cpuCount = newValue
                save()
            }
            .onChange(of: memorySize) { newValue in
                document.content.memorySize = UInt64(newValue) * 1024 * 1024 * 1024
                save()
            }
            .onChange(of: diskSize) { newValue in
                document.content.diskSize = UInt64(newValue) ?? 32
                save()
            }
        }
    }
    
    func save() {
        undoManager?.registerUndo(withTarget: document, handler: { _ in })
    }
}
