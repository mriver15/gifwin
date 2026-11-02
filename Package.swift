// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gifwin",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "gifwin", targets: ["gifwin"])], // encoder-checks is dev-only, not a product
    targets: [
        .target(name: "GifwinCore"),
        .executableTarget(name: "gifwin", dependencies: ["GifwinCore"]),
        .executableTarget(name: "encoder-checks", dependencies: ["GifwinCore"]),
    ],
    swiftLanguageModes: [.v5]
)
