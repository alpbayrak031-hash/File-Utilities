// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileUtilities",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FileUtilities", path: "Sources/FileUtilities")
    ]
)
