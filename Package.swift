// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallflow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WallflowKit"),
        .executableTarget(name: "WallflowApp", dependencies: ["WallflowKit"]),
        .testTarget(name: "WallflowKitTests", dependencies: ["WallflowKit"]),
    ]
)
