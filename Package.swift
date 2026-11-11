// swift-tools-version: 5.9
import PackageDescription

// The parser has no Apple-framework dependencies and can be tested on Linux.
// The converter and app deliberately build only on macOS.
var products: [Product] = [
    .library(name: "MotionPhotoCore", targets: ["MotionPhotoCore"])
]
var targets: [Target] = [
    .target(name: "MotionPhotoCore"),
    .testTarget(name: "MotionPhotoCoreTests", dependencies: ["MotionPhotoCore"])
]

#if os(macOS)
products.append(.executable(name: "MotionPhotoBridge", targets: ["MotionPhotoBridgeApp"]))
targets += [
    .target(
        name: "LivePhotoEngine",
        dependencies: ["MotionPhotoCore"],
        linkerSettings: [
            .linkedFramework("AVFoundation"),
            .linkedFramework("CoreMedia"),
            .linkedFramework("CoreVideo"),
            .linkedFramework("CoreLocation"),
            .linkedFramework("AudioToolbox"),
            .linkedFramework("ImageIO"),
            .linkedFramework("Photos"),
            .linkedFramework("UniformTypeIdentifiers")
        ]
    ),
    .executableTarget(
        name: "MotionPhotoBridgeApp",
        dependencies: ["MotionPhotoCore", "LivePhotoEngine"],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("SwiftUI"),
            .linkedFramework("AVKit"),
            .linkedFramework("PhotosUI")
        ]
    ),
    .testTarget(
        name: "LivePhotoEngineTests",
        dependencies: ["LivePhotoEngine", "MotionPhotoCore"],
        resources: [.copy("Fixtures")]
    )
]
#endif

let package = Package(
    name: "MotionPhotoBridge",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
