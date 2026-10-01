// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ryft",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Ryft", targets: ["Ryft"])],
    targets: [
        .target(name: "RyftWindowLayout"),
        .testTarget(name: "RyftWindowLayoutTests", dependencies: ["RyftWindowLayout"]),
        .executableTarget(
            name: "Ryft",
            dependencies: ["RyftWindowLayout"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreWLAN")
            ]
        )
    ]
)
