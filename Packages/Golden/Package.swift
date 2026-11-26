// swift-tools-version: 6.0
import PackageDescription

// 비교 도구는 화면 계산까지 조합하므로 별도 최상위 패키지에 둔다.
let package = Package(
    name: "Golden",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "mdemo-golden", targets: ["mdemo-golden"])],
    dependencies: [
        .package(path: "../MemoCore"), .package(path: "../Services"),
        .package(path: "../Features"), .package(path: "../StickyWindow"),
        .package(path: "../MarkdownEngine"),
    ],
    targets: [.executableTarget(name: "mdemo-golden", dependencies: [
        .product(name: "MemoCore", package: "MemoCore"),
        .product(name: "Services", package: "Services"),
        .product(name: "Features", package: "Features"),
        .product(name: "StickyWindow", package: "StickyWindow"),
        .product(name: "MarkdownEngine", package: "MarkdownEngine"),
    ])]
)
