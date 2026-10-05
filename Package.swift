// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Muxbar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Built-in terminal pane. Pinned to 1.11.2: 1.12+ adds Metal shaders, which need Xcode's
        // `metal` compiler and so can't build with Command Line Tools alone.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2"),
    ],
    targets: [
        .target(name: "MuxbarCore"),
        .executableTarget(name: "Muxbar", dependencies: [
            "MuxbarCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(
            name: "MuxbarCoreTests",
            dependencies: ["MuxbarCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
