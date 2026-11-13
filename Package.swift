// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PgQueryUpdater",
    platforms: [.macOS(.v12)],
    products: [],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: []
)
