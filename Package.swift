// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SaunaAutomation",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WorkspaceDirectory", targets: ["WorkspaceDirectory"])],
    targets: [
        .target(name: "WorkspaceDirectory"),
        .testTarget(name: "WorkspaceDirectoryTests", dependencies: ["WorkspaceDirectory"]),
    ]
)
