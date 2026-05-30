// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "llama", targets: ["llama"])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip",
            checksum: "db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a"
        )
    ]
)
