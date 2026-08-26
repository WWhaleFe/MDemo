// swift-tools-version: 6.0
import PackageDescription

// 마크다운 파싱 · 실시간 변환 규칙(InputRule) · 직렬화. 순수 로직, UI 의존성 없음.
// 새 마크다운 문법 추가는 이 패키지에 InputRule 타입을 더하는 것으로 끝나야 한다.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"])
    ],
    dependencies: [
        .package(path: "../TestKit")
    ],
    targets: [
        .target(name: "MarkdownEngine"),
        .executableTarget(
            name: "MarkdownEngineTests",
            dependencies: [
                "MarkdownEngine",
                .product(name: "TestKit", package: "TestKit"),
            ],
            path: "Tests/MarkdownEngineTests"
        ),
    ]
)
