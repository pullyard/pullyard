// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PullYard",
    platforms: [.macOS("14.5")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.2.0")
    ],
    targets: [
        .target(
            name: "StackNotesKit",
            path: "Sources/StackNotesKit"
        ),
        .executableTarget(
            name: "pullyard-mcp",
            dependencies: ["StackNotesKit"],
            path: "Sources/PullYardMCP"
        ),
        .executableTarget(
            name: "PullYard",
            dependencies: ["StackNotesKit", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "IrohLib", package: "iroh-ffi")],
            path: "Sources/PullYard"
        ),
        .testTarget(
            name: "PullYardTests",
            dependencies: ["PullYard", "StackNotesKit"],
            path: "Tests/PullYardTests"
        )
    ]
)
