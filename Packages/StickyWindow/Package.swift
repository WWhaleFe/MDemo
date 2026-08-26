// swift-tools-version: 6.0
import PackageDescription

// 플로팅 스티키 창 계층: 프레임리스 NSPanel, 투명도 분리 적용, 창 위치/크기 관리.
let package = Package(
    name: "StickyWindow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StickyWindow", targets: ["StickyWindow"])
    ],
    dependencies: [
        .package(path: "../MemoCore"),
        .package(path: "../EditorKit"),
        .package(path: "../Services"),
        .package(path: "../TestKit"),
    ],
    targets: [
        .target(
            name: "StickyWindow",
            dependencies: [
                .product(name: "MemoCore", package: "MemoCore"),
                .product(name: "EditorKit", package: "EditorKit"),
                .product(name: "Services", package: "Services"),
            ]
        ),
        .executableTarget(
            name: "StickyWindowTests",
            dependencies: [
                "StickyWindow",
                .product(name: "TestKit", package: "TestKit"),
            ],
            path: "Tests/StickyWindowTests"
        ),
    ]
)
