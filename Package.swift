// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Silt",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Silt", targets: ["Silt"]),
        .executable(name: "silt-bench", targets: ["silt-bench"]),
    ],
    targets: [
        .target(
            name: "SiltCore",
            cSettings: [.unsafeFlags(["-O3", "-Wall", "-Wextra", "-Wno-unused-parameter"])]
        ),
        .executableTarget(
            name: "silt-bench",
            dependencies: ["SiltCore"],
            linkerSettings: [.linkedFramework("CoreServices")]
        ),
        .executableTarget(
            name: "Silt",
            dependencies: ["SiltCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-enforce-exclusivity=unchecked"]),
            ],
            linkerSettings: [.linkedFramework("Quartz")]
        ),
        .testTarget(name: "SiltCoreTests", dependencies: ["SiltCore"]),
        .testTarget(
            name: "SiltAppTests",
            dependencies: ["Silt"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
