// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenDictation",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "OpenDictation",
            path: "Sources/OpenDictation"
        )
    ]
)
