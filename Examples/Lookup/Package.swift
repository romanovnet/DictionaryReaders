// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "ReaderLookup",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "Lookup", dependencies: [
        .product(name: "DictionaryReaders", package: "DictionaryReaders"),
    ])]
)
