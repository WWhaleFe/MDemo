// swift-tools-version: 6.0
import PackageDescription

// 기능 계층(SwiftUI): 리스트 창 · 환경설정 창.
// 창은 필요할 때 만들고 닫으면 완전히 해제한다 (숨김 유지 금지 — 메모리 원칙 §4-5).
let package = Package(
    name: "Features",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Features", targets: ["Features"])
    ],
    dependencies: [
        .package(path: "../MemoCore"),
        .package(path: "../Services"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                .product(name: "MemoCore", package: "MemoCore"),
                .product(name: "Services", package: "Services"),
            ]
        )
    ]
)
