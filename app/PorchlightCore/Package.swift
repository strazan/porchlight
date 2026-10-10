// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PorchlightCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PorchlightCore", targets: ["PorchlightCore"]),
        .executable(name: "porchlight-cli", targets: ["porchlight-cli"]),
    ],
    targets: [
        .target(name: "PorchlightCore"),
        .executableTarget(name: "porchlight-cli", dependencies: ["PorchlightCore"]),
        .testTarget(
            name: "PorchlightCoreTests",
            dependencies: ["PorchlightCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
