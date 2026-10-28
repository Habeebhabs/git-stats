// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Worklog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Worklog", targets: ["Worklog"]),
        .library(name: "WorklogCore", targets: ["WorklogCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "WorklogCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "Worklog",
            dependencies: ["WorklogCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "WorklogCoreTests",
            dependencies: ["WorklogCore"]
        ),
    ]
)
