// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KitsuneLauncher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KitsuneLauncher", targets: ["KitsuneLauncher"]),
        .executable(name: "kitsunectl", targets: ["KitsuneCLI"]),
    ],
    targets: [
        .target(
            name: "CLua",
            path: "Vendor/lua-5.4.8/src",
            exclude: ["lua.c", "luac.c", "Makefile"],
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .headerSearchPath("."),
            ],
            linkerSettings: [.linkedLibrary("readline")]
        ),
        .executableTarget(
            name: "KitsuneLauncher",
            dependencies: ["CLua"],
            path: "Sources/KitsuneLauncher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(name: "KitsuneCLI", path: "Sources/KitsuneCLI"),
        .testTarget(name: "KitsuneLauncherTests", dependencies: ["KitsuneLauncher"], path: "Tests/KitsuneLauncherTests"),
    ]
)
