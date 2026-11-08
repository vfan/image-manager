// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageManager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ImageManager", targets: ["ImageManager"])
    ],
    targets: [
        // All app code lives in the library target so it can be unit-tested.
        .target(
            name: "ImageManagerCore",
            path: "ImageManager"
        ),
        // Thin @main executable that links the core library.
        .executableTarget(
            name: "ImageManager",
            dependencies: ["ImageManagerCore"],
            path: "ImageManagerApp"
        ),
        .testTarget(
            name: "ImageManagerTests",
            dependencies: ["ImageManagerCore"],
            path: "Tests/ImageManagerTests"
        ),
    ]
)
