// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayPageCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "DayPageCore", targets: ["DayPageCore"])],
    targets: [
        .target(name: "DayPageCore"),
        .testTarget(name: "DayPageCoreTests", dependencies: ["DayPageCore"])
    ]
)
