// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Encore",
            path: "Sources/Encore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
