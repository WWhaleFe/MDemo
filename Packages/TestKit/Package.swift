// swift-tools-version: 6.0
import PackageDescription

// 테스트 전용 최소 러너.
//
// 왜 swift-testing/XCTest이 아닌가: 이 개발 환경에는 Xcode 없이 Command Line Tools만 있고,
// CLT의 Testing.framework은 런타임 라이브러리(lib_TestingInterop.dylib)가 빠져 있어 실행되지 않는다.
// Xcode를 설치하면 각 패키지의 테스트 타깃을 .testTarget + swift-testing으로 되돌리면 된다.
let package = Package(
    name: "TestKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TestKit", targets: ["TestKit"])
    ],
    targets: [
        .target(name: "TestKit")
    ]
)
