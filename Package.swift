// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Revnix",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "Revnix", targets: ["Revnix"])
    ],
    targets: [
        .target(name: "Revnix", path: "Sources/Revnix"),
        .testTarget(
            name: "RevnixTests", dependencies: ["Revnix"], path: "Tests/RevnixTests",
            resources: [
                .copy("Resources/Revnix.storekit"),
                .copy("Resources/paywall-background-wire.json"),
            ]
        ),
    ]
)
