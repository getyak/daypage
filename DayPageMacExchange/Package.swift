// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "DayPageMacExchange", defaultLocalization: "en", platforms: [.macOS(.v13)],
  products: [.library(name: "DayPageMacExchange", targets: ["DayPageMacExchange"])],
  dependencies: [.package(path: "../DayPageCore")],
  targets: [
    .target(name: "DayPageMacExchange", dependencies: [.product(name: "DayPageCore", package: "DayPageCore")],
      resources: [.process("Resources")]),
    .testTarget(name: "DayPageMacExchangeTests", dependencies: ["DayPageMacExchange", .product(name: "DayPageCore", package: "DayPageCore")]),
  ]
)
