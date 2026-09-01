// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CABDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CABDesktop", targets: ["CABDesktop"]),
    ],
    targets: [
        .target(name: "CABContinuity"),
        .executableTarget(name: "CABDesktop", dependencies: ["CABContinuity"]),
        .testTarget(name: "CABDesktopTests", dependencies: ["CABDesktop", "CABContinuity"]),
    ]
)
