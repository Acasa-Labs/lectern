// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Folio",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
