// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DayPageKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "DayPageModels", targets: ["DayPageModels"]),
        .library(name: "DayPageStorage", targets: ["DayPageStorage"]),
        .library(name: "DayPageServices", targets: ["DayPageServices"]),
    ],
    dependencies: [
        // Sentry is intentionally NOT a Kit dependency.
        //
        // The Sentry SDK ships a pre-built xcframework pinned to the Swift
        // compiler version it was built with. Declaring Sentry as a Kit
        // dependency caused Xcode to resolve a SECOND copy with a different
        // Swift version than the app target's own Sentry, breaking the iOS
        // build with "this SDK is not supported by the compiler" errors.
        //
        // Instead, Kit exposes a `SentryAdapter` protocol (see
        // DayPageStorage/SentryReporter.swift). App targets implement it with
        // a thin wrapper around `Sentry.SentrySDK` and register the adapter at
        // launch via `SentryReporter.adapter = AppSentryAdapter()`.
    ],
    targets: [
        .target(
            name: "DayPageModels"
        ),
        .target(
            name: "DayPageStorage",
            dependencies: [
                "DayPageModels",
            ]
        ),
        .target(
            name: "DayPageServices",
            dependencies: [
                "DayPageModels",
                "DayPageStorage",
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
