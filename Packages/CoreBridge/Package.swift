// swift-tools-version: 6.0
import PackageDescription

// Rust 경계를 감싸는 최하위 계층. 생성 파일은 build-core.sh가 준비한다.
let package = Package(
    name: "CoreBridge",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CoreBridge", targets: ["CoreBridge"])],
    dependencies: [.package(path: "../TestKit")],
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
            dependencies: [
                "CoreBridge",
                .product(name: "TestKit", package: "TestKit"),
            ],
            path: "Tests/CoreBridgeTests"
        ),
    ]
)
