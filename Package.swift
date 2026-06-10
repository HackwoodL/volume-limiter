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
        .library(name: "VolumeLimitCLI", targets: ["VolumeLimitCLI"]),
        .executable(name: "volume-limiterd", targets: ["VolumeLimiterDaemon"]),
        .executable(name: "volume-limit", targets: ["VolumeLimitExecutable"]),
        .executable(name: "volume-limiter-tests", targets: ["VolumeLimiterTestRunner"])
    ],
    targets: [
        .target(name: "VolumeLimiterCore"),
        .target(name: "VolumeLimiterIPC"),
        .target(
            name: "VolumeLimitCLI",
            dependencies: ["VolumeLimiterIPC"]
        ),
        .executableTarget(
            name: "VolumeLimiterDaemon",
            dependencies: [
                "VolumeLimiterCore",
                "VolumeLimiterIPC"
            ],
            path: "Sources/volume-limiterd"
        ),
        .executableTarget(
            name: "VolumeLimitExecutable",
            dependencies: ["VolumeLimitCLI"],
            path: "Sources/volume-limit"
        ),
        .executableTarget(
            name: "VolumeLimiterTestRunner",
            dependencies: [
                "VolumeLimiterCore",
                "VolumeLimitCLI",
                "VolumeLimiterIPC"
            ],
            path: "Tests/VolumeLimiterTestRunner"
        )
    ]
)
