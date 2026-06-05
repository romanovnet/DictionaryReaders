// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DictionaryReaders",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [.library(name: "DictionaryReaders", targets: ["DictionaryReaders"])],
    targets: [
        .target(name: "DictionaryReaders"),
        .testTarget(name: "DictionaryReadersTests", dependencies: ["DictionaryReaders"]),
    ]
)
