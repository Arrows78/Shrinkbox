// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shrinkbox",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Shrinkbox", path: "Sources/Shrinkbox")
    ]
)
