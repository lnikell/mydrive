// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyDriveCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MyDriveCore", targets: ["MyDriveCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MyDriveCore", dependencies: ["CSQLite"]),
        .testTarget(name: "MyDriveCoreTests", dependencies: ["MyDriveCore"])
    ]
)
