// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayPageKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DayPageModels", targets: ["DayPageModels"]),
        .library(name: "DayPageStorage", targets: ["DayPageStorage"]),
        .library(name: "DayPageServices", targets: ["DayPageServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "DayPageModels"
        ),
        .target(
            name: "DayPageStorage",
            dependencies: [
                "DayPageModels",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .target(
            name: "DayPageServices",
            dependencies: [
                "DayPageModels",
                "DayPageStorage",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ]
        ),
        .testTarget(
            name: "DayPageModelsTests",
            dependencies: ["DayPageModels"]
        ),
        .testTarget(
            name: "DayPageStorageTests",
            dependencies: ["DayPageStorage", "DayPageModels"]
        ),
        .testTarget(
            name: "DayPageServicesTests",
            dependencies: ["DayPageServices", "DayPageStorage", "DayPageModels"]
        ),
    ]
)
