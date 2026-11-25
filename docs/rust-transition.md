# Rust 전환(C안) 시작 안내

다른 세션에서 "Rust 전환 시작"을 요청받으면 이 문서부터 읽는다. 결정과 계획은 노션 계획표가 기준이고, 화면은 디자인 캔버스가 기준이다.

## 기준과 목표

- 기준판: **v0.13.0** (main `a8e0dea`, 2026-11-26 릴리스). 구글 드라이브 동기화 · 노션에 보내기 · iCloud 동기화 제거까지 들어간 Swift 판.
- 목표판: **v0.14.0** = 핵심 Rust + 화면 Swift (C안).
- 목표 두 가지
  1. 암호 처리의 한계 극복: 열쇠 · 암호 · 복호화한 본문을 Rust zeroize 버퍼에만 두고, 실패 횟수 · 10회 파기 규칙을 Rust 한 곳에서 강제.
  2. Windows 호환: 같은 핵심 코드를 Windows에서 빌드 · 테스트하고, 맥과 Windows가 같은 구글 드라이브 `MDemo` 폴더로 맞춘다.
- 원칙: 사용자가 보는 동작과 디스크 파일은 기준판과 같다. 화면(AppKit · SwiftUI)은 그대로 두고 화면 아래 계층만 바꾼다.

## 불러올 자료

| 자료 | 위치 | 쓰는 곳 |
|---|---|---|
| 전환 계획표 (범위 · 숨은 동작 표 · 검수 방법 · P0~P8 · 위험) | 노션 "C안 전환 계획표: 핵심 Rust + 화면 Swift" https://app.notion.com/p/42334b7a9e74819b84c0ed7efd240a65 | 작업 순서와 끝나는 조건 |
| 비교 보고서 (Swift / Rust 100% / 혼합) | 노션 https://app.notion.com/p/42334b7a9e748186a8d8f207120f0408 | 왜 C안인지 |
| 디자인 캔버스 | https://claude.ai/artifact/Miegtzz59fGtBeLrzB8kcc | 화면 유지 기준 |
| ↳ 화면 지도 | 캔버스 보드 `ScreenMap.dc.html` "v0.14(Rust 전환) 화면 지도" | 화면 12개의 배치 · 문구 · 단축키(바꾸지 않을 것) |
| ↳ 맥 → Windows 대응표 | 캔버스 보드 `PlatformMap.dc.html` | Windows판 화면 계획(P8 다음) |
| ↳ 암호 아이콘 | 캔버스 보드 `LockIcons.dc.html` (B + D안 채택) | 기호 좌표는 `MemoGlyphs.lock` |

캔버스는 Artifact 도구로 `action: "read"`, `path: "project/ScreenMap.dc.html"`처럼 읽는다. 고칠 때는 최신판을 읽은 뒤 그 위에 고쳐 다시 올린다.

## 처음 할 일: P0 기준선

1. 노션 계획표 2장 "먼저 고칠 기존 버그" 3건을 Swift에서 고친다(프론트매터 따옴표 순서 · 줄바꿈, 라벨 토큰 `~` 증식, 영구 삭제의 잠긴 메모 판별). v0.13.x로 낸다.
2. 2장 숨은 동작 표를 실행 가능한 테스트로 고정한다. v0.13.0에서 더해진 것도 포함한다.
   - 구글 드라이브 거울: 드라이브 ↔ 거울은 md5(`drive-state.json`), 거울 ↔ 데이터는 동기화 엔진(`sync-state-google.json` · `.hashes.json`).
   - 첫 동기화는 합치기만, 목록 · 내려받기 실패 시 그 회차는 아무것도 지우지 않음, 드라이브 삭제는 영구 삭제.
   - 충돌 사본은 같은 회차에 반대쪽까지 올림(`SyncReport.conflictCopies`).
   - 바뀐 것이 없으면 메모를 다시 쓰지 않음(`MemoStore.updateMeta` · `saveBody`).
3. 골든 파일 생성기와 두 구현(Swift / Rust) 실행기를 만든다. 이 단계에서는 Rust 코드를 쓰지 않는다.
4. 줄 수 · 테스트 수는 v0.12.0 때 값이라 다시 센다.

## 지킬 것

- 실제 데이터 폴더(`~/Library/Application Support/MDemo/Data`)는 바꾸지 않는다. 시험은 `--data-dir=<시험 폴더>`로.
  - 실제 구글 동기화 시험: `--data-dir=… --google-sync-test` (토큰은 `com.wwhalefe.MDemo.google.devtest`)
  - 실제 노션 보내기 시험: `--data-dir=… --notion-test` (토큰은 `com.wwhalefe.MDemo.notion.devtest`)
- 테스트는 실제 네트워크 · 홈 폴더 · 데이터 폴더 · 키체인을 건드리지 않는다(TestKit, 메모리 키체인).
- 암호 메모는 어떤 동기화 · 업로드에도 들어가지 않는다.
- OAuth 실제 값(`App/Resources/GoogleOAuth.plist`, `NotionOAuth.plist`)은 git에 올리지 않는다. 노션 비밀키는 Vercel 환경 변수에만 있다(프로젝트 `mdemo-notion-oauth`).
- Windows판 OAuth는 같은 구글 클라우드 프로젝트에 데스크톱 클라이언트를 하나 더 만든다(`drive.file`은 프로젝트 단위).
- 커밋 · 푸시 · 릴리스는 요청받았을 때만. 릴리스는 `make dist` → GitHub 릴리스 → `wwhalefe/tap`의 `Casks/mdemo.rb` 버전 · 해시 → `brew uninstall`(--zap 없이) 후 `brew install --cask mdemo`, 설치 전후 메모 수 · 지문 비교.
- `make build` · `make test` · `make check`(계층 · 네트워크 예외 점검)가 모두 통과해야 한다.
