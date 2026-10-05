// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "connect-my-world-in-herdr",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ConnectMyWorld", targets: ["ConnectMyWorld"]),
               .executable(name: "ConnectionCheck", targets: ["ConnectionCheck"])],
    targets: [
        .target(name: "ConnectionCore"),
        .executableTarget(name: "ConnectMyWorld", dependencies: ["ConnectionCore"]),
        .executableTarget(name: "ConnectionCheck", dependencies: ["ConnectionCore"]),
        .testTarget(name: "ConnectionCoreTests", dependencies: ["ConnectionCore"])
    ]
)
