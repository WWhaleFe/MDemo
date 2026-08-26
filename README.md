# MemoApp

macOS용 개인 메모앱. 바탕화면에 떠 있는 마크다운 스티키 노트.

- 기능 명세: [memo-app-feature-spec.md](memo-app-feature-spec.md)
- 아키텍처 · 개발 프로세스: [memo-app-architecture.md](memo-app-architecture.md)
- 마일스톤 측정 기록: [docs/measurements.md](docs/measurements.md)

현재 상태: **M1 진행 중** — 마크다운 저장·자동 저장·창 복원·실시간 서식 변환까지 동작한다.
남은 것은 한글 입력 수동 확인([docs/manual-test-ime.md](docs/manual-test-ime.md)) 하나다.

동작하는 것: 메뉴바 상주, 플로팅 스티키 창, 마크다운 파일 자동 저장, 재시작 시 창 복원,
입력 중 서식 변환(제목·목록·체크박스·굵게·기울임·취소선·형광·코드).

아직 없는 것: 리스트 창(M3), iCloud 동기화(M4), 전역 단축키·이미지·알람(M5).

## 빌드와 실행

이 프로젝트는 **Xcode 없이 Command Line Tools만으로** 빌드된다.

```bash
make build     # 디버그 빌드 + build/MemoApp.app 생성
make run       # 빌드 후 실행 (메뉴바에 메모 아이콘이 나타난다)
make test      # 전 패키지 테스트
make check     # 계층 규칙 · 네트워크 코드 검사
make mem       # 실행 중인 앱의 메모리 사용량
make release   # arm64 + x86_64 유니버설 번들
```

앱은 Dock에 뜨지 않는다(LSUIElement). 종료는 메뉴바 아이콘 → 종료.

메모리 측정용으로 실행과 동시에 메모를 띄우려면:

```bash
open build/MemoApp.app --args --new-memo --new-memo   # 인자 수만큼 창 생성
```

## 프로젝트 구조

계층은 아래에서 위로만 의존한다. 이 방향이 깨지면 `make check`가 실패한다.

```
App/                    앱 타깃 — 조립(DI), 메뉴바
Packages/
  Features/             리스트 창 · 환경설정 (SwiftUI)          [M3]
  StickyWindow/         플로팅 창, 투명도 적용                   [M0~M2]
  EditorKit/            NSTextView 편집기, 한글 IME 처리          [M1]
  Services/             알람 · 단축키 · 백업 · iCloud 동기화       [M4~M5]
  MarkdownEngine/       파싱 · 실시간 변환 규칙(InputRule)        [M1]
  MemoCore/             모델 · 저장소 · 검색 인덱스               [M1]
  TestKit/              테스트 러너 (Xcode 부재 대응)
```

`MemoCore` · `MarkdownEngine` · `Services`는 AppKit을 import하지 않는다. iOS 확장(SYNC-11)에서 그대로 재사용하기 위한 규칙이다.

## 기능 추가 규칙

1. 새 마크다운 문법 → `MarkdownEngine`에 `InputRule` 타입 추가. 에디터 본체는 건드리지 않는다.
2. 새 창 동작 → `StickyWindow`에 Behavior 파일 추가. `StickyPanel`을 비대하게 만들지 않는다.
3. 상태 변경은 `MemoStore`를 거친다. UI에서 저장소를 직접 호출하지 않는다.
4. 파일 포맷 변경 → `schemaVersion` 증가 + 마이그레이션 + 왕복 테스트를 한 커밋에 담는다.
5. 커밋 메시지에는 스펙 ID를 쓴다. 예: `feat(WIN-05): 창 위치/크기 자동 저장`

## 개발 환경 메모

- Xcode 미설치 환경이라 `.xcodeproj` 대신 SwiftPM + `Scripts/bundle.sh`로 `.app`을 만든다. 프로젝트 파일이 전부 텍스트라 diff와 병합이 쉽다는 이점도 있다.
- CLT의 `Testing.framework`은 런타임 라이브러리가 빠져 있어 `swift test`가 동작하지 않는다. 그래서 `Packages/TestKit`의 최소 러너를 쓴다. Xcode를 설치하면 각 패키지를 `.testTarget` + swift-testing으로 되돌릴 수 있다.
- Xcode를 설치했다면 라이선스에 한 번 동의해야 툴체인이 열린다. 동의 전에는 `Scripts/toolchain.sh`가 자동으로 Command Line Tools로 되돌려 빌드를 계속한다.

  ```bash
  sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
  ```
- 서명은 ad-hoc(`codesign -s -`). 유료 개발자 계정을 확보하면 `Scripts/bundle.sh`의 서명 줄만 Developer ID로 바꾸면 된다.
