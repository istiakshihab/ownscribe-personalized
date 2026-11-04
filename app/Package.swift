// swift-tools-version: 6.2
import PackageDescription

// The ownscribe recorder app. Built into ownscribe.app by build.sh (no Xcode project needed).
let package = Package(
    name: "OwnscribeApp",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "OwnscribeApp",
            path: "Sources/OwnscribeApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
