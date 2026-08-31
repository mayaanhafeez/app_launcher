// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitLauncher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OrbitLauncher", targets: ["OrbitLauncher"]),
        .executable(name: "orbitctl", targets: ["OrbitCLI"]),
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
            name: "OrbitLauncher",
            dependencies: ["CLua"],
            path: "Sources/OrbitLauncher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(name: "OrbitCLI", path: "Sources/OrbitCLI"),
        .testTarget(name: "OrbitLauncherTests", dependencies: ["OrbitLauncher"], path: "Tests/OrbitLauncherTests"),
    ]
)
