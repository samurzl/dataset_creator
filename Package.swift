// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoDatasetBrowser",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VideoDatasetBrowser", targets: ["VideoDatasetBrowser"])
    ],
    targets: [
        .executableTarget(
            name: "VideoDatasetBrowser",
            path: "Sources"
        ),
        .testTarget(
            name: "VideoDatasetBrowserTests",
            dependencies: ["VideoDatasetBrowser"],
            path: "Tests/VideoDatasetBrowserTests"
        )
    ]
)
