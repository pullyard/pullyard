// swift-tools-version:5.10
import Foundation
import PackageDescription

let withIroh = ProcessInfo.processInfo.environment["PULLYARD_NO_IROH"] == nil

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")
]
var appDependencies: [Target.Dependency] = ["StackNotesKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
if withIroh {
    packageDependencies.append(.package(url: "https://github.com/n0-computer/iroh-ffi", exact: "1.2.0"))
    appDependencies.append(.product(name: "IrohLib", package: "iroh-ffi"))
}

let package = Package(
    name: "PullYard",
    platforms: [.macOS("14.5")],
    dependencies: packageDependencies,
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
            dependencies: appDependencies,
            path: "Sources/PullYard"
        ),
        .testTarget(
            name: "PullYardTests",
            dependencies: ["PullYard", "StackNotesKit"],
            path: "Tests/PullYardTests"
        )
    ]
)
