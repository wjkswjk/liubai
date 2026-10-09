// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Liubai",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Liubai", targets: ["Liubai"])],
    targets: [
        .executableTarget(name: "Liubai"),
        .testTarget(name: "LiubaiTests", dependencies: ["Liubai"])
    ],
    swiftLanguageModes: [.v5]
)
