// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacWall",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacWallKit"),
        .executableTarget(name: "MacWall", dependencies: ["MacWallKit"]),
        .testTarget(name: "MacWallKitTests", dependencies: ["MacWallKit"]),
    ]
)
