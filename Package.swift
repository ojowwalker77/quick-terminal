// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickTerm",
    platforms: [.macOS("26.0")],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "QuickTerm",
            dependencies: ["GhosttyKit"],
            path: "Sources/QuickTerm",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
