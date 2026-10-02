// swift-tools-version: 6.0
import PackageDescription

// 앱 타깃. 조립(DI)과 메뉴바만 담당하고, 실제 기능은 Packages/ 아래 계층 모듈에 있다.
// 계층 규칙은 memo-app-architecture.md §2 참고. Scripts/check-layering.sh 가 이를 검사한다.
let package = Package(
    name: "MDemo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MDemo", targets: ["MDemo"])
    ],
    dependencies: [
        .package(path: "Packages/MemoCore"),
        .package(path: "Packages/MarkdownEngine"),
        .package(path: "Packages/EditorKit"),
        .package(path: "Packages/StickyWindow"),
        .package(path: "Packages/Services"),
        .package(path: "Packages/Features"),
    ],
    targets: [
        .executableTarget(
            name: "MDemo",
            dependencies: [
                .product(name: "MemoCore", package: "MemoCore"),
                .product(name: "MarkdownEngine", package: "MarkdownEngine"),
                .product(name: "EditorKit", package: "EditorKit"),
                .product(name: "StickyWindow", package: "StickyWindow"),
                .product(name: "Services", package: "Services"),
                .product(name: "Features", package: "Features"),
            ],
            path: "App/Sources/MDemo"
        )
    ]
)
