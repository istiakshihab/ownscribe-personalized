// swift-tools-version: 6.2
import PackageDescription

// Earshot, the recorder app for ownscribe. Built into Earshot.app by build.sh (no Xcode project needed).
let package = Package(
    name: "Earshot",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Earshot",
            path: "Sources/Earshot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
