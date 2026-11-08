// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayPageCore",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9)],
    products: [.library(name: "DayPageCore", targets: ["DayPageCore"]),
               .library(name: "DayPageCapture", targets: ["DayPageCapture"])],
    targets: [
        .target(name: "DayPageCapture"),
        .target(name: "DayPageCore", dependencies: ["DayPageCapture"]),
        .testTarget(name: "DayPageCoreTests", dependencies: ["DayPageCore"], resources: [.copy("Fixtures")])
    ]
)
