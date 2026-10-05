// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirDropDrawer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AirDropDrawer", targets: ["AirDropDrawer"])],
    targets: [
        .target(name: "DrawerCore"),
        .executableTarget(name: "AirDropDrawer", dependencies: ["DrawerCore"]),
        .executableTarget(name: "DrawerCoreChecks", dependencies: ["DrawerCore"], path: "Tests/DrawerCoreTests")
    ]
)
