// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "AppleSDKMacRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppleSDKMacRuntime", type: .dynamic, targets: ["AppleSDKMacRuntime"])
    ],
    targets: [
        .target(name: "AppleSDKMacRuntime")
    ]
)
