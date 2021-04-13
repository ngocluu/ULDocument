// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ULDocument",
    platforms: [.iOS(.v11)],
    products: [
        .library(name: "ULDocument", targets: ["ULDocument"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
    ],
    targets: [
        .target(
            name: "ULDocument",
            dependencies: [],
            path: "Source",
            exclude: ["Other"],
            cSettings: [
                .headerSearchPath("../Header"),
                .headerSearchPath("Utilities")
            ]
        )
    ]
)
