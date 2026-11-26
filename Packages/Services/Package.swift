// swift-tools-version: 6.0
import PackageDescription

// 서비스 계층: 알람 · 전역 단축키 · 백업 · iCloud 스냅숏 동기화(SyncService).
// AppKit 의존 금지(글자 인식용 Vision은 허용, 맥 안에서만 돈다) - iOS에서도 재사용한다.
let package = Package(
    name: "Services",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Services", targets: ["Services"])
    ],
    dependencies: [
        .package(path: "../MemoCore"),
        .package(path: "../CoreBridge"),
        .package(path: "../MarkdownEngine"),
        .package(path: "../TestKit"),
    ],
    targets: [
        .target(
            name: "Services",
            dependencies: [
                .product(name: "MemoCore", package: "MemoCore"),
                .product(name: "CoreBridge", package: "CoreBridge"),
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
            ]
        ),
        .executableTarget(
            name: "ServicesTests",
            dependencies: [
                "Services",
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
                .product(name: "TestKit", package: "TestKit"),
            ],
            path: "Tests/ServicesTests"
        ),
    ]
)
