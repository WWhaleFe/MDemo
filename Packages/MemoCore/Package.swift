// swift-tools-version: 6.0
import PackageDescription

// 데이터 계층: 모델 · 저장소 · 검색 인덱스.
// UI 프레임워크(AppKit/SwiftUI) 의존성 금지 — iOS 확장(SYNC-11)의 전제 조건이다.
let package = Package(
    name: "MemoCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MemoCore", targets: ["MemoCore"])
    ],
    dependencies: [
        .package(path: "../TestKit")
    ],
    targets: [
        .target(name: "MemoCore"),
        // Xcode가 없는 환경이라 .testTarget 대신 실행 가능한 러너를 쓴다 (TestKit 참고).
        .executableTarget(
            name: "MemoCoreTests",
            dependencies: [
                "MemoCore",
                .product(name: "TestKit", package: "TestKit"),
            ],
            path: "Tests/MemoCoreTests"
        ),
    ]
)
