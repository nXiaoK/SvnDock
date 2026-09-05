// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SvnDock",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SvnDockCore", targets: ["SvnDockCore"]),
        .executable(name: "SvnDock", targets: ["SvnDockApp"]),
        .library(name: "SvnDockFinderExtension", targets: ["SvnDockFinderExtension"]),
        .executable(name: "SvnDockAgent", targets: ["SvnDockAgent"]),
        .executable(name: "SvnDockCoreSmoke", targets: ["SvnDockCoreSmoke"])
    ],
    targets: [
        .target(
            name: "SvnDockCore",
            path: "SvnDockCore"
        ),
        .executableTarget(
            name: "SvnDockApp",
            dependencies: ["SvnDockCore"],
            path: "SvnDockApp",
            exclude: ["README.md", "Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "SvnDockFinderExtension",
            path: "FinderExtension",
            exclude: [
                "README.md",
                "Info.plist",
                "FinderExtension.entitlements",
                "FinderExtension.entitlements.example"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("FinderSync")
            ]
        ),
        .executableTarget(
            name: "SvnDockAgent",
            dependencies: ["SvnDockCore"],
            path: "SvnDockAgent",
            exclude: [
                "README.md",
                "Info.plist",
                "SvnDockAgent.entitlements",
                "SvnDockAgent.entitlements.example",
                "com.svndock.agent.plist.example"
            ]
        ),
        .executableTarget(
            name: "SvnDockCoreSmoke",
            dependencies: ["SvnDockCore"],
            path: "SvnDockCoreSmoke",
            swiftSettings: [
                .define("SVNDOCK_SMOKE_TESTS")
            ]
        ),
        .testTarget(
            name: "SvnDockCoreTests",
            dependencies: ["SvnDockCore"],
            path: "SvnDockCoreTests"
        ),
        .testTarget(
            name: "SvnDockAppTests",
            dependencies: ["SvnDockApp"],
            path: "SvnDockAppTests",
            exclude: ["SmokeMain.swift"]
        ),
        .testTarget(
            name: "SvnDockFinderExtensionTests",
            dependencies: ["SvnDockFinderExtension"],
            path: "FinderExtensionTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
