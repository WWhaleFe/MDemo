// swift-tools-version: 6.0
import PackageDescription

// Rust 경계를 감싸는 최하위 계층. 생성 파일은 build-core.sh가 준비한다.
let package = Package(
    name: "CoreBridge",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CoreBridge", targets: ["CoreBridge"])],
    dependencies: [.package(path: "../TestKit"), .package(path: "../MarkdownEngine")],
    targets: [
        .binaryTarget(name: "MDemoCoreFFI", path: "../../build/core/MDemoCoreFFI.xcframework"),
        // UniFFI 0.28 생성 코드는 Swift 5 동시성 규칙을 기준으로 한다.
        .target(
            name: "CoreBridge",
            dependencies: ["MDemoCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CoreBridgeTests",
            // 규칙 일치와 지연 비교를 위해 시험에서만 Swift 구현(MarkdownEngine)을 함께 쓴다.
            dependencies: [
                "CoreBridge",
                .product(name: "TestKit", package: "TestKit"),
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
            ],
            path: "Tests/CoreBridgeTests"
        ),
    ]
)
