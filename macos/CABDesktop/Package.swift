// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CABDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CABDesktop", targets: ["CABDesktop"]),
    ],
    targets: [
        .executableTarget(name: "CABDesktop"),
    ]
)
