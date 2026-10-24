// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PullYard",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
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
            dependencies: ["StackNotesKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/PullYard"
        ),
        .testTarget(
            name: "PullYardTests",
            dependencies: ["PullYard", "StackNotesKit"],
            path: "Tests/PullYardTests"
        )
    ]
)
