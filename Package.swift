// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuietDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuietDesk", targets: ["QuietDesk"]),
        .executable(name: "QuietDeskChecks", targets: ["QuietDeskChecks"])
    ],
    targets: [
        .target(name: "QuietDeskCore"),
        .executableTarget(name: "QuietDesk", dependencies: ["QuietDeskCore"]),
        .executableTarget(name: "QuietDeskChecks", dependencies: ["QuietDeskCore"], path: "Checks")
    ]
)
