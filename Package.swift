// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenAIQuotaBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenAIQuotaBar", targets: ["OpenAIQuotaBar"])],
    targets: [
        .executableTarget(name: "OpenAIQuotaBar", resources: [.copy("Resources")]),
        .testTarget(name: "OpenAIQuotaBarTests", dependencies: ["OpenAIQuotaBar"], resources: [.copy("Fixtures")])
    ]
)
