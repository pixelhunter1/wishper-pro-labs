// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WishperPro",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "WishperPro",
            targets: ["WishperPro"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "WishperPro"
        ),
    ]
)
