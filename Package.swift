// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VolumeLimiter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VolumeLimiterCore", targets: ["VolumeLimiterCore"]),
        .library(name: "VolumeLimiterIPC", targets: ["VolumeLimiterIPC"]),
        .executable(name: "volume-limiterd", targets: ["VolumeLimiterDaemon"]),
        .executable(name: "volume-limiter-tests", targets: ["VolumeLimiterTestRunner"])
    ],
    targets: [
        .target(name: "VolumeLimiterCore"),
        .target(name: "VolumeLimiterIPC"),
        .executableTarget(
            name: "VolumeLimiterDaemon",
            dependencies: [
                "VolumeLimiterCore",
                "VolumeLimiterIPC"
            ],
            path: "Sources/volume-limiterd"
        ),
        .executableTarget(
            name: "VolumeLimiterTestRunner",
            dependencies: [
                "VolumeLimiterCore",
                "VolumeLimiterIPC"
            ],
            path: "Tests/VolumeLimiterTestRunner"
        )
    ]
)
