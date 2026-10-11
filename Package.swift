// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Anakena",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Anakena",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnakenaTests",
            dependencies: ["Anakena"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
