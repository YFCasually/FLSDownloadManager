// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FLSDownloadManager",
    platforms: [.iOS(.v17)],
    products: [.library(name: "FLSDownloadManager", targets: ["FLSDownloadManager"])],
    targets: [
        .target(name: "FLSDownloadManager"),
        .testTarget(name: "FLSDownloadManagerTests", dependencies: ["FLSDownloadManager"])
    ]
)
