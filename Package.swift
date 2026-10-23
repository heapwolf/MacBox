// swift-tools-version:6.0

import PackageDescription

// `swift build` compiles the executable; `make` wraps it into a signed MacBox.app.
// Virtualization.framework refuses to run without the entitlements in App/, so use the app bundle.
let package = Package(
    name: "MacBox",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MacBox",
            path: "Sources/MacBox",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
