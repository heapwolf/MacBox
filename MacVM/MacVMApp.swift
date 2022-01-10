//
//  MacVMApp.swift
//  MacVM
//
//  Created by Khaos Tian on 6/28/21.
//

import SwiftUI
import Combine

@main
struct MacVMApp: App {
    
    private let passThrough = PassthroughSubject<Void, Never>()
    
    var body: some Scene {
        DocumentGroup {
            VMDocument();
        } editor: { configuration in
            VMView(
                document: configuration.document,
                fileURL: configuration.fileURL
            )
            .onReceive(passThrough) { _ in
                guard let fileURL = configuration.fileURL else {
                    return
                }

                if configuration.document.isRunning {
                    configuration.document.vmInstance?.stop()
                } else {
                    configuration.document.createVMInstance(with: fileURL)
                    configuration.document.vmInstance?.start()
                }
            }
        }.commands {
            CommandMenu("Virtual Machine") {
                Button("Toggle Start/Stop") {
                    passThrough.send()
                }
                .keyboardShortcut("S")
              }
        }

    }
}
