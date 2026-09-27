// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoomScheduler",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZoomScheduler", targets: ["ZoomScheduler"])],
    targets: [
        .executableTarget(name: "ZoomScheduler"),
        .testTarget(name: "ZoomSchedulerTests", dependencies: ["ZoomScheduler"])
    ]
)
