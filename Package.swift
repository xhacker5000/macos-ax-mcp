// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macos-ax-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macos-ax-mcp", targets: ["MacOSAXMCP"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSAXMCP",
            path: "Sources/MacOSAXMCP",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "MacOSAXMCPTests",
            dependencies: ["MacOSAXMCP"],
            path: "Tests/MacOSAXMCPTests"
        ),
    ]
)
