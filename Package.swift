// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileSyncMonitor",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FileSyncMonitor", targets: ["FileSyncMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "FileSyncMonitor",
            dependencies: [],
            path: "Sources/FileSyncMonitor",
            resources: [
                .process("Resources")
            ],
            exclude: ["Info.plist", "FileSyncMonitor.entitlements"]
        )
    ]
)
