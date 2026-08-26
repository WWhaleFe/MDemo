// swift-tools-version: 6.0
import PackageDescription

// 에디터 계층: NSTextView 기반 편집기, 실시간 서식 적용, 한글 IME 처리(NFR-08).
let package = Package(
    name: "EditorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EditorKit", targets: ["EditorKit"])
    ],
    dependencies: [
        .package(path: "../MemoCore"),
        .package(path: "../MarkdownEngine"),
    ],
    targets: [
        .target(
            name: "EditorKit",
            dependencies: [
                .product(name: "MemoCore", package: "MemoCore"),
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
            ]
        )
    ]
)
