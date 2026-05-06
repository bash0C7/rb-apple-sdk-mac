// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "AppleSDKMacRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppleSDKMacRuntime", type: .dynamic, targets: ["AppleSDKMacRuntime"])
    ],
    targets: [
        .target(
            name: "AppleSDKMacRuntime",
            linkerSettings: [
                // libruby symbols (rb_hash_new, rb_global_variable, rb_obj_id, etc.)
                // are referenced by @_silgen_name in RuntimeBridge.swift but not
                // available at link time — they're resolved at dlopen against the
                // Ruby process's libruby via flat-namespace lookup.
                .unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])
            ]
        )
    ]
)
