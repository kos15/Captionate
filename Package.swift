// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Captionate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Captionate",
            path: "Sources/Captionate"
        )
    ]
)
