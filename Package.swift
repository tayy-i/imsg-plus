// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imsg-plus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IMsgCore", targets: ["IMsgCore"]),
        .executable(name: "imsg-plus", targets: ["imsg-plus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/Commander.git", from: "0.2.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "IMsgCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("Contacts"),
            ]
        ),
    .executableTarget(
        name: "imsg-plus",
        dependencies: [
            "IMsgCore",
            .product(name: "Commander", package: "Commander"),
        ],
        exclude: [
            "Resources/Info.plist",
        ],
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/imsg-plus/Resources/Info.plist",
            ])
        ]
    ),
        .testTarget(
            name: "IMsgCoreTests",
            dependencies: [
                "IMsgCore",
            ]
        ),
        .testTarget(
            name: "imsg-plusTests",
            dependencies: [
                "imsg-plus",
                "IMsgCore",
            ]
        ),
    ]
)
