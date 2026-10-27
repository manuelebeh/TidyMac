// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TidyMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TidyCore", targets: ["TidyCore"]),
        .executable(name: "TidyMac", targets: ["TidyMac"]),
    ],
    targets: [
        .target(name: "TidyCore"),
        .executableTarget(name: "TidyMac", dependencies: ["TidyCore"]),
        .testTarget(name: "TidyCoreTests", dependencies: ["TidyCore"]),
    ]
)
