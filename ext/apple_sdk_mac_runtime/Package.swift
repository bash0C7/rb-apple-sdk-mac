// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "AppleSDKMacRuntime",
    platforms: [.macOS(.v27)],
    products: [
        .library(
            name: "AppleSDKMacRuntime",
            type: .dynamic,
            targets: ["AppleSDKMacRuntime"]
        ),
    ],
    targets: [
        .target(
            name: "AppleSDKMacRuntime",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"]),
            ]
        ),
    ]
)
