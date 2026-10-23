// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Renvert",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RenvertCore", targets: ["RenvertCore"]),
        .executable(name: "Renvert", targets: ["Renvert"])
    ],
    targets: [
        .target(
            name: "RenvertCore",
            path: "Sources/RenvertCore"
        ),
        .executableTarget(
            name: "Renvert",
            dependencies: ["RenvertCore"],
            path: "Sources/Renvert",
            exclude: ["Info.plist", "Renvert.entitlements", "InfoPlist.xcstrings"],
            resources: [
                .process("Resources"),
                .process("Assets.xcassets"),
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "RenvertCoreTests",
            dependencies: ["RenvertCore"],
            path: "Tests/RenvertCoreTests"
        )
    ]
)
