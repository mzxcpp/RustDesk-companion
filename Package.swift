// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RustDisplay",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 系统设置跳转（MIT，内置副本见 Vendor/PermissionFlow/VENDORED.md）
        .package(path: "Vendor/PermissionFlow"),
        // 首次启动功能导览（MIT，内置副本见 Vendor/TourKit/VENDORED.md）
        .package(path: "Vendor/TourKit"),
    ],
    targets: [
        .target(name: "CGVirtualDisplayBridge"),
        .target(name: "RustDeskCore"),
        .executableTarget(
            name: "RustDisplay",
            dependencies: [
                "CGVirtualDisplayBridge",
                "RustDeskCore",
                .product(name: "SystemSettingsKit", package: "PermissionFlow"),
                .product(name: "TourKit", package: "TourKit"),
            ]
        ),
        .executableTarget(
            name: "rustdesk-tests",
            dependencies: ["RustDeskCore"]
        ),
    ]
)
