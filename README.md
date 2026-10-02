# MDemo

**노션과 잘 이어지는 마크다운 메모앱.** macOS 바탕화면에 떠 있는 스티키 노트로 빠르게 적고,
노션과 복사 · 붙여넣기로 서식째 주고받는다. 이것이 이 앱을 만든 목적이다.

- **메모 → 노션:** 메모에서 ⌘C로 복사해 노션에 ⌘V로 붙여 넣으면 제목 · 목록 · 체크박스 · 번호 목록 ·
  인용 · 코드 · 표 · 굵게/기울임/취소선이 노션 블록으로 그대로 들어간다.
- **노션 → 메모:** 노션에서 복사해 메모에 붙여 넣으면 같은 서식으로 들어간다. 하위 목록 단계도 지킨다.
- 쓰는 동안에는 마크다운 기호를 숨기고 서식만 보여 준다 (`# `, `- [ ] `, `**굵게**`를 치면 바로 바뀐다).
- 저장은 늘 표준 마크다운이다. 메모 하나가 `.md` 파일 하나라 노션 · Obsidian 등 다른 도구에서도 읽힌다.
- 메뉴바에 상주하고, 메모는 다른 창 위에 떠 있어 일하면서 바로 적을 수 있다.

(0.9.0까지 이름은 MemoApp이었다. 다른 앱과 겹쳐 저장소·코드·앱 식별자·저장 폴더를 모두 MDemo로 바꿨다.
예전 버전의 메모와 설정은 MDemo를 처음 켤 때 새 자리로 복사된다. 원본은 지우지 않는다.)

## ⬇️ 다운로드 (macOS)

[최신 릴리스](https://github.com/WWhaleFe/MDemo/releases/latest)에서 `MDemo-vX.Y.Z.zip`을 받아
압축을 풀고 **응용 프로그램** 폴더로 옮긴다. `.dmg`를 받았다면 열어서 Applications로 끌어다 놓는다.

- 유니버설(Apple Silicon + Intel), macOS 14 이상.
- 아직 공증(notarization)을 받지 않은 임시 서명 앱이다. 처음 열면 macOS가 막는데,
  **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"**를 누르면 된다.
  (macOS 15부터는 Finder 우클릭 → "열기"로는 넘어가지 않는다.)
- 메뉴바 앱이라 Dock에는 뜨지 않는다. 화면 위쪽 메뉴바의 메모 아이콘에서 쓴다.

## 📋 노션과 주고받기

메모와 노션 사이에서는 그냥 ⌘C · ⌘V를 쓰면 된다.

| | 메모 → 노션 | 노션 → 메모 |
|---|---|---|
| 제목 1~3 · 글머리 · 번호 · 체크박스 · 인용 · 구분선 | ✓ | ✓ |
| 하위 목록 단계 | ✓ (4칸 들여쓰기) | ✓ (2칸 · 4칸 · 탭 모두 인식) |
| 코드 박스 · 표 | ✓ | ✓ |
| 굵게 · 기울임 · 취소선 · 코드 글자 | ✓ | ✓ |
| 글자 색 · 형광펜 | 글자만 (노션 마크다운에는 색 문법이 없다) | — |

- 화면에는 `•` · `☐` 같은 표식만 보이지만, 복사할 때는 고른 부분을 마크다운으로 되돌려 넣는다.
  한 줄 안의 일부만 고르면 글자 서식만 가져간다.
- 글이 있는 줄 가운데에 붙여 넣으면 그 줄의 모양(목록 · 제목)은 지키고 글자 서식만 들어간다.
- 서식 없이 글자만 붙여 넣으려면 ⌥⇧⌘V.

## 🔄 업데이트

메뉴바 메뉴 아래쪽(종료 바로 위)에 버전과 업데이트 항목이 있다.

- **업데이트 확인…** — GitHub의 최신 릴리스와 비교해 결과를 한 줄로 보여 준다 (✓ 최신 / 🔵 새 버전 / ⚠️ 실패).
- **최신 버전 다운로드** — 최신 릴리스의 zip을 다운로드 폴더에 받고 Finder에서 보여 준다.
  다 받은 뒤 다시 누르면 Finder에서 다시 보여 주고, 실패했으면 릴리스 페이지를 연다.
  임시 서명 앱이라 자동으로 바꿔 끼우지 않는다 — 압축을 풀어 응용 프로그램에 덮어쓰면 된다.
- **릴리스 페이지 열기** — 버전별 변경 내용과 파일을 브라우저에서 본다.
- **업데이트 자동 확인** — 켤 때 한 번, 그 뒤 하루에 한 번 확인한다. 새 버전은 버전마다 한 번만 알린다.
- 메모와 설정은 앱 밖(`~/Library/Application Support/MDemo/Data`, 사용자 기본값)에 있어서
  앱을 바꿔도 그대로 남는다.
- 앱이 외부와 통신하는 것은 이 업데이트 확인 하나뿐이다 (NFR-07). 메모 내용은 보내지 않는다.

## 📦 릴리스 절차

버전은 `App/Resources/Info.plist` 한 곳에서 관리한다.

1. `CFBundleShortVersionString`(예: `0.9.1`)과 `CFBundleVersion`(빌드 번호, 1씩 증가)을 올린다.
2. `make test && make dist` — `build/dist/MDemo-vX.Y.Z.zip`과 `.dmg`가 생긴다.
3. 커밋: `vX.Y.Z: 바뀐 점 요약`
4. 태그와 릴리스: `gh release create vX.Y.Z build/dist/MDemo-vX.Y.Z.zip build/dist/MDemo-vX.Y.Z.dmg --title "MDemo vX.Y.Z" --notes-file <노트>`

앱의 업데이트 확인은 태그(`v` 뒤의 숫자)와 앱 버전을 비교하고, 릴리스의 `.zip`을 내려받는다.
그래서 태그 이름과 zip 첨부는 이 꼴을 지켜야 한다.

## 개발

- 기능 명세: [memo-app-feature-spec.md](memo-app-feature-spec.md)
- 아키텍처 · 개발 프로세스: [memo-app-architecture.md](memo-app-architecture.md)
- 마일스톤 측정 기록: [docs/measurements.md](docs/measurements.md)

현재 상태: **v0.9.1 (테스트 배포)**

동작하는 것: 메뉴바 상주, 플로팅 스티키 창(크기 조절·투명도·배경색·접기·제목), 마크다운 자동 저장,
입력 중 서식 변환과 서식 막대(제목·목록·체크박스·인용·코드 박스·표·굵게·기울임·취소선·글자 색·형광펜),
슬래시 명령, 리스트 창(그룹·검색·정렬·복수 선택·휴지통), iCloud 스냅숏 동기화,
노션과 서식째 복사 · 붙여넣기, 편집 단축키(⌘C · ⌘V · ⌘X · ⌘A · ⌘Z),
서식·전역 단축키, 로그인 시 자동 실행, 백업, GitHub 릴리스 업데이트 확인.

아직 없는 것: 이미지 첨부, 알람.

## 문제를 확인하는 방법

창 상태나 그리기와 얽힌 문제는 자동 테스트로 잡히지 않는다. 앱을 직접 실행해 확인한다.

```bash
# 슬래시 팝업이 뜨는지 + 실제 치수 (스크롤·정렬 확인)
./build/MDemo.app/Contents/MacOS/MDemo --new-memo --demo-slash

# 특정 명령을 치고 엔터까지 눌러 본다 (적용·크래시 확인)
./build/MDemo.app/Contents/MacOS/MDemo --new-memo --demo-command=제목
```

앱이 종료됐다면 `~/Library/Logs/DiagnosticReports/MDemo-*.ips`에 원인이 남는다.

## 빌드와 실행

이 프로젝트는 **Xcode 없이 Command Line Tools만으로** 빌드된다.

```bash
make build     # 디버그 빌드 + build/MDemo.app 생성
make run       # 빌드 후 실행 (메뉴바에 메모 아이콘이 나타난다)
make test      # 전 패키지 테스트
make check     # 계층 규칙 · 네트워크 코드 검사
make mem       # 실행 중인 앱의 메모리 사용량
make release   # arm64 + x86_64 유니버설 번들
make dist      # 배포 파일 build/dist/MDemo-vX.Y.Z.zip · .dmg
```

앱은 Dock에 뜨지 않는다(LSUIElement). 종료는 메뉴바 아이콘 → 종료.

메모리 측정용으로 실행과 동시에 메모를 띄우려면:

```bash
open build/MDemo.app --args --new-memo --new-memo   # 인자 수만큼 창 생성
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
