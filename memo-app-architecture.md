# 메모앱 아키텍처 및 개발 프로세스 설계서

- 기준 문서: [memo-app-feature-spec.md](memo-app-feature-spec.md) v1.0
- 작성일: 2026-08-26
- 버전: v1.0
- 목적: 기능 명세를 실제로 구현하기 위한 기술 스택, 모듈 구조, 데이터 설계, 개발 프로세스를 확정한다. 유지보수와 기능 추가가 쉬운 구조를 최우선으로 한다.

---

## 1. 기술 스택 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| 언어 | Swift 5.10+ | NFR-06 (네이티브 필수) |
| 최소 지원 OS | macOS 14 (Sonoma) | SMAppService(macOS 13+), 최신 SwiftUI/Observation 매크로 사용. 필요 시 13으로 하향 가능하나 코드 복잡도 증가 |
| 창/에디터 | **AppKit** (NSPanel + NSTextView/TextKit) | 프레임리스 플로팅 창(WIN-02/03/07), 투명도 레이어 제어(OPA-*), 한글 IME 안정성(NFR-08)은 AppKit이 아니면 제어 불가 |
| 리스트 창/환경설정 | **SwiftUI** (NSHostingView로 탑재) | 목록/폼 UI는 SwiftUI가 생산성·유지보수성 우위 |
| 텍스트 엔진 | TextKit 1 기반 NSTextView | TextKit 2는 한글 조합(마크드 텍스트) 중 실시간 속성 변경 시 이슈 이력이 있음. NFR-08이 P0급 품질 기준이므로 검증된 TextKit 1로 시작. 엔진 교체가 가능하도록 에디터를 모듈로 격리 |
| 상태 관리 | Observation(@Observable) + 단방향 데이터 흐름 | 별도 프레임워크(TCA 등) 도입하지 않음 — 초경량 원칙, 의존성 최소화 |
| 검색 인덱스 | SQLite (GRDB.swift) | DOC-03. FTS5로 SRC-01 성능 목표(NFR-05) 달성. GRDB는 가볍고 성숙함 |
| YAML 프론트매터 | Yams | DOC-02 파싱/직렬화 |
| 전역 단축키 | Carbon RegisterEventHotKey 직접 래핑 또는 KeyboardShortcuts 라이브러리 | KEY-11, SYS-04. 라이브러리 사용 시 SET-05(재지정 UI)까지 해결됨 |
| 기기 간 동기화 | **iCloud Drive 일반 폴더에 스냅숏 저장/불러오기** (주기 자동 + 수동). 유비쿼티 컨테이너·CloudKit 미사용 | SYNC-*. 유료 개발자 계정 없이 동작 — iCloud Drive 폴더는 entitlement가 필요 없다. 작업 데이터는 항상 로컬(메모리·성능 원칙), iCloud는 동기화 저장소로만 사용 (상세 §4-4) |
| 외부 의존성 정책 | 위 3개(GRDB, Yams, KeyboardShortcuts) 외 추가 금지 | NFR-01(30MB), NFR-07(네트워크 코드 없음) |
| 빌드 시스템 | **SwiftPM + `Scripts/bundle.sh`** (Xcode 프로젝트 없음) | 개발 환경에 Xcode가 없고 Command Line Tools만 있다. 부수 효과로 프로젝트 정의가 전부 텍스트라 diff·병합이 쉽다 |
| 테스트 | **`Packages/TestKit` 자체 러너** | CLT의 `Testing.framework`은 런타임 라이브러리(`lib_TestingInterop.dylib`)가 빠져 있어 `swift test`가 실행되지 않는다. Xcode 설치 시 swift-testing으로 복귀 가능 |
| 서명 | ad-hoc (`codesign -s -`) | 유료 계정 없음. 확보 시 `bundle.sh`의 서명 줄만 교체 |

---

## 2. 모듈 구조 (핵심 설계)

**앱 타깃 하나에 코드를 몰아넣지 않고, 로컬 Swift Package로 계층을 분리한다.**
이것이 "추후 업데이트/기능 추가가 편한 구조"의 핵심 장치다. 각 모듈은 아래 계층 방향으로만 의존한다 (위 → 아래 단방향).

```
┌─────────────────────────────────────────────┐
│  MDemo (앱 타깃)                              │  조립·DI·AppDelegate·메뉴바
├──────────────┬──────────────┬───────────────┤
│ StickyWindow │  ListFeature │ SettingsFeature│  기능 계층 (Feature)
│  (AppKit)    │  (SwiftUI)   │  (SwiftUI)     │
├──────────────┴──────┬───────┴───────────────┤
│  EditorKit (AppKit) │  Services              │  에디터 / 서비스 계층
│                     │  (Alarm·Hotkey·Backup) │
├─────────────────────┴───────────────────────┤
│  MarkdownEngine                              │  파싱·실시간 변환 규칙 (UI 무관, 순수 로직)
├─────────────────────────────────────────────┤
│  MemoCore                                    │  모델·저장소·검색 인덱스 (UI 무관)
└─────────────────────────────────────────────┘
```

### 2-1. MemoCore — 데이터 계층 (UI 의존성 0)

| 구성요소 | 책임 | 관련 스펙 |
|---|---|---|
| `Memo`, `MemoMeta`, `Group` | 도메인 모델. `MemoMeta`가 프론트매터와 1:1 대응 | DOC-02 |
| `FrontmatterCodec` | 마크다운 파일 ↔ (메타, 본문) 변환. `schemaVersion` 마이그레이션 포함 | DOC-01/02 |
| `MemoRepository` (protocol) | 저장소 추상 인터페이스. CRUD, 휴지통, 그룹 | ↓ |
| `FileMemoRepository` | 로컬 파일 기반 구현. **원자적 저장**(임시 파일 → rename), 첨부 관리. **본문 지연 로드**: 목록용으로는 메타+미리보기만 읽고, 본문 전체는 창을 열 때만 로드 | DAT-01/03/08, IMG-07, NFR-02 |
| `SearchIndex` | SQLite FTS5 캐시. 파일이 항상 원본, 인덱스는 언제든 재생성 가능. **동기화 제외, 기기별 보관** | DOC-03, SRC-01, NFR-05 |
| `MemoStore` (@Observable) | 앱 전체의 단일 진실 공급원(single source of truth). 모든 UI는 이것만 구독. **상주 데이터는 메타+미리보기뿐, 본문은 열린 메모만 보유** (§4-5) | 전역, NFR-02 |

`MemoRepository`를 프로토콜로 두는 이유: 저장 방식의 교체·확장이 상위 계층 수정 없이 가능해야 한다. iCloud 스냅숏 동기화(§4-4)는 Repository 위에서 동작하는 `SyncService`(Services 계층)로 구현되고, 추후 유료 계정 확보 시 실시간 동기화(SYNC-10)나 FUT-02(자체 서버)로 업그레이드할 때도 데이터 계층은 수정이 없다.

### 2-2. MarkdownEngine — 순수 로직 계층 (UI 의존성 0)

| 구성요소 | 책임 | 관련 스펙 |
|---|---|---|
| `MarkdownParser` | 본문 → 블록/인라인 토큰. DOC-04 허용 확장(`==`, `=50%`)만 지원 | DOC-04 |
| `InputRule` (protocol) + 규칙 배열 | **실시간 변환을 규칙 플러그인으로 구현.** `HeadingRule`, `BulletRule`, `CheckboxRule`, `BoldRule`… 각각 독립 타입 | MD-01~13 |
| `MarkdownSerializer` | 편집 상태 → 표준 마크다운 문자열 (저장용) | DOC-01, CHK-05 |
| `SlashCommand` 정의 | 명령 목록·필터 로직 (팝업 UI는 EditorKit 담당) | SL-01~05 |

`InputRule` 플러그인 구조가 확장성의 두 번째 핵심 장치다. MD-10~12(P2, 코드 블록/인용/구분선) 추가는 규칙 타입 하나 추가로 끝난다. 순수 로직이므로 **유닛 테스트가 가장 두터워야 할 모듈**이다.

### 2-3. EditorKit — 에디터 계층

| 구성요소 | 책임 | 관련 스펙 |
|---|---|---|
| `MemoTextView: NSTextView` | 편집기 본체. 서식 단축키, Tab 들여쓰기 | KEY-01~09 |
| `LiveFormatController` | NSTextStorage 변경 감지 → MarkdownEngine 규칙 적용. **`hasMarkedText() == true`(한글 조합 중)이면 변환을 보류하고 조합 확정 후 적용** | MD-*, NFR-08 |
| `CheckboxAttachment` | 클릭 가능한 체크박스 (NSTextAttachment) | CHK-01/02 |
| `ImageAttachment` + 리사이즈 핸들 | 이미지 표시/드래그 크기 조절 | IMG-01/03/04 |
| `SlashPopup` | 슬래시 명령 팝업 창 | SL-01~03 |
| Undo 관리 | 자동 변환을 별도 undo 그룹으로 등록 → Cmd+Z 1회에 원문 복원 | MD-13 |

한글 IME 처리(NFR-08)는 이 앱의 최대 기술 리스크이므로 `LiveFormatController`에 격리하고, M1 마일스톤에서 가장 먼저 검증한다.

### 2-4. StickyWindow — 플로팅 창 계층

| 구성요소 | 책임 | 관련 스펙 |
|---|---|---|
| `StickyPanel: NSPanel` | 프레임리스, `isOpaque=false`, `level=.floating` 토글, `collectionBehavior` 설정, 8방향 리사이즈 | WIN-01~07, WIN-10 |
| `StickyWindowController` | 창 1개 = 메모 1개. 배경 레이어 알파 / 텍스트 알파 분리 적용 (스펙 3장 구현 원칙 준수, `window.alphaValue`는 항상 1.0) | OPA-01~05 |
| `WindowRegistry` | 열린 창 관리, 위치/크기 → 메타 저장, 재시작 복원, 다중 모니터 화면 밖 보정 | WIN-05/06, SYS-05 |
| `CollapseBehavior` | 제목 한 줄 접기/펼치기 | WIN-08 |
| `HoverOpacityBehavior` | 호버 시 불투명화 (NSTrackingArea) | OPA-04 |

창 동작(접기, 호버 등)을 Behavior 단위로 분리해 옵션 on/off(SET-03)와 P2 기능 추가(블러 OPA-07, 클릭 통과 OPA-08)를 각각 독립 파일로 수용한다.

### 2-5. Services

| 서비스 | 책임 | 관련 스펙 |
|---|---|---|
| `AlarmService` | UNUserNotificationCenter 예약/반복/권한, 알림 클릭 라우팅 | ALM-01~07 |
| `HotkeyService` | 전역 단축키 등록 (새 메모, 모두 보이기/숨기기) | KEY-11, SYS-04 |
| `BackupService` | ZIP 내보내기/복원, .md/.html/.pdf 내보내기, 가져오기 | DAT-04~07 |
| `SyncService` | iCloud Drive 스냅숏 저장(push)/불러오기(pull) — 수동 + 주기 자동. 메모별 병합·충돌 사본 생성, 상태 보고. 백그라운드 큐에서 변경분만 처리 | SYNC-* |
| `LaunchAtLoginService` | SMAppService 래핑 | SYS-03 |

### 2-6. 앱 타깃 (MDemo)

- `AppDelegate`: LSUIElement 메뉴바 상주, 메뉴 구성 (SYS-01/02)
- `AppContainer`: 의존성 조립(수동 DI — 생성자 주입만 사용, DI 프레임워크 금지)
- ListFeature / SettingsFeature: SwiftUI 뷰 + 뷰모델 (LST-*, SRC-*, TRS-*, SET-*)

---

## 3. 데이터 설계

### 3-1. 저장 폴더 구조

데이터를 세 영역으로 나눈다: **작업 데이터(항상 로컬)**, **기기 로컬 상태**, **iCloud 동기화 저장소(스냅숏)**. 앱은 iCloud 폴더를 직접 작업 폴더로 쓰지 않는다 — 미다운로드 파일이나 iCloud I/O 지연이 편집 경로에 끼어들지 않게 하고, 편집 중 메모리·I/O 부하를 로컬 파일 수준으로 유지하기 위해서다.

```
[작업 데이터 — 항상 로컬, 원본]
  기본: ~/Library/Application Support/MDemo/Data/  (사용자 지정 가능, DAT-02)
├── memos/
│   ├── 01H8XKQ2V9/                # 메모별 폴더 (폴더명 = 메모 ID, ULID)
│   │   ├── memo.md                # 프론트매터 + 본문 (열림 상태 포함 → 미러링의 근거)
│   │   └── attachments/           # 이 메모의 이미지 (IMG-07)
│   │       └── a1b2c3.png
│   └── 01H8XKR7M2/ ...
├── trash/                         # 휴지통 = 메모 폴더를 통째로 이동 (TRS-01)
└── groups.json                    # 그룹 목록·정렬 (기기 간 공유 대상)

[기기 로컬 상태 — 동기화 제외]  ~/Library/Application Support/MDemo/
├── index.sqlite                   # 검색 캐시. 파일에서 언제든 재생성 (DOC-03), 기기별 보관
└── device-state.json              # 이 기기에서의 창 위치/크기/모니터 매핑/접힘 상태 (SYNC-07)

[iCloud 동기화 저장소 — 스냅숏]  ~/Library/Mobile Documents/com~apple~CloudDocs/MDemo/  (SYNC-01)
├── memos/ · trash/ · groups.json  # 작업 데이터와 동일 구조의 사본 (push/pull 대상)
└── sync-manifest.json             # 메모별 modified 목록 — 변경분 판별·병합에 사용
```

- **메모별 폴더 방식 채택** (미결정 4번): 휴지통 이동/복원(TRS-01/02)과 첨부 동반 삭제(TRS-05)가 "폴더 이동/삭제" 하나로 끝나 원자성이 보장됨. 동기화 시에도 메모 단위 전파가 폴더 단위로 이루어짐.
- ID는 ULID: 시간순 정렬 가능 + 충돌 없음. 파일명·프론트매터·커밋 메시지에 동일 사용.
- 그룹(LST-02)은 폴더가 아니라 프론트매터의 `group` 필드 + `groups.json`의 그룹 목록으로 관리 → 그룹 이동 시 파일 이동 불필요, 동기화 충돌 표면적 최소화.
- **기기 종속/공유 데이터 분리 원칙 (SYNC-07)**: "이 메모가 떠 있는가"(open, pinned)는 사용자 의도이므로 **공유**하고, "어디에 어떤 크기로 떠 있는가"(frame, display, collapsed)는 기기마다 화면 구성이 다르므로 **로컬**에 둔다. 이 분리 덕에 창을 옮기는 조작이 동기화 대상 파일을 건드리지 않아 스냅숏 push가 가벼워진다.

### 3-2. 프론트매터 스키마

스펙 예시에 `schemaVersion`을 추가하고(미결정 3번 → **넣는다**로 확정 권고), 동기화 요구에 따라 스펙 DOC-02의 필드 구성을 조정한다: **기기 종속 필드(frame, display, collapsed)는 프론트매터에서 제외**하고 `device-state.json`으로 옮긴다 (SYNC-07). 대신 기기 간 공유해야 하는 `open`(열림 상태)을 추가한다 — 이것이 열린 창 미러링(SYNC-08)의 데이터 근거다.

```yaml
---
schemaVersion: 1
id: 01H8XKQ2V9
group: 업무            # 없으면 미지정 (LST-03)
color: "#FFF3B0"
bgAlpha: 0.85          # 메모별 투명도 (OPA-05) — 사용자 의도이므로 동기화
textAlpha: 1.0
open: true             # 플로팅 창으로 떠 있는가 — 기기 간 공유 (SYNC-08)
pinned: true           # 항상 위 (WIN-03) — 기기 간 공유
alarm: { at: "2026-09-01T09:00", repeat: weekly, weekdays: [mon] }
created: 2026-08-26T10:00:00+09:00
modified: 2026-08-26T10:30:00+09:00
---
```

`device-state.json` (기기 로컬, 메모 ID를 키로 창 기하 정보만 보관):

```json
{
  "01H8XKQ2V9": { "frame": [1200, 340, 320, 400], "display": "37D8802C-...", "collapsed": false }
}
```

마이그레이션 규칙: `FrontmatterCodec`이 로드 시 `schemaVersion`을 보고 순차 마이그레이션 → 저장 시 항상 최신 버전으로 기록. 알 수 없는 필드는 **보존**한다(구버전 앱이 신버전 파일을 열어도 데이터 유실 없음).

### 3-3. 저장 파이프라인 (DAT-03/08)

```
키 입력 → NSTextStorage 변경
  → 0.5초 디바운스 → MarkdownSerializer로 직렬화
  → 임시 파일 기록 → fsync → rename(원자적 교체)  (DAT-08)
  → SearchIndex 갱신 (백그라운드 큐)
창 이동/리사이즈/접기 → 0.5초 디바운스 → device-state.json 갱신 (기기 로컬)
창 열기/닫기, 색·투명도 변경 → 프론트매터 갱신 저장
주기 도래·수동 실행·앱 종료 → SyncService push: 변경분만 iCloud 스냅숏에 복사 (§4-4)
앱 시작·주기 도래·수동 실행 → SyncService pull: 스냅숏의 최신 변경을 로컬로 병합 (§4-4)
앱 종료 → 디바운스 무시하고 즉시 flush 후 push
```

### 3-4. 검색 인덱스

- SQLite FTS5 가상 테이블: `(memo_id, title, body, group, modified)`
- 앱 시작 시 파일 mtime과 인덱스를 대조해 변경분만 재인덱싱. 인덱스 손상/부재 시 전체 재생성.
- 검색 흐름: 리스트 창 입력 → FTS5 질의(전방/부분 일치) → 결과 memo_id로 `MemoStore` 조회. NFR-05(1,000개 0.3초) 충족.

---

## 4. 핵심 기술 설계 포인트

### 4-1. 플로팅 창 (WIN-*, OPA-*)

```swift
// StickyPanel 핵심 설정
styleMask = [.nonactivatingPanel, .fullSizeContentView, .resizable]
isOpaque = false
backgroundColor = .clear
alphaValue = 1.0                        // 항상 고정 (스펙 3장 구현 원칙)
level = pinned ? .floating : .normal    // WIN-03 토글
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // WIN-04
hidesOnDeactivate = false
```

- 배경: `backgroundView.layer.backgroundColor = color.withAlphaComponent(bgAlpha)` (OPA-01)
- 텍스트: `textColor.withAlphaComponent(textAlpha)` — 에디터의 기본 속성 + 렌더 속성 재적용 (OPA-02)
- 하한선은 슬라이더 range 자체를 0.15/0.3부터 시작 (OPA-03)
- 8방향 리사이즈: 프레임리스이므로 가장자리 8개 히트존을 직접 구현 (`resizeEdge` 판정 → mouseDragged에서 frame 갱신)
- 닫기 버튼 = `orderOut` + 메타의 열림 상태 해제. 파일은 유지 (WIN-10)

### 4-2. 실시간 변환과 한글 IME (MD-*, NFR-08)

처리 순서 (가장 중요한 규칙):

1. `NSTextStorage.processEditing` 후크에서 변경 라인 파악
2. **`textView.hasMarkedText() == true`이면 아무것도 하지 않는다** — 조합 중 속성 변경이 글자 깨짐의 원인
3. 조합 확정(`insertText`) 시점에 보류된 라인에 `InputRule` 배열을 순회 적용
4. 변환 적용 시 `undoManager.beginUndoGrouping()`으로 독립 그룹 생성 (MD-13)
5. 서식은 NSAttributedString 속성으로만 표현하고, 원본 마크다운 기호는 커스텀 속성에 보존 → 직렬화 시 복원

### 4-3. 상태 흐름 (단방향)

```
사용자 액션 (창/에디터/리스트)
   → MemoStore 메서드 호출 (유일한 변경 창구)
   → Repository 저장 + @Observable 상태 갱신
   → 구독 중인 모든 UI 자동 반영 (리스트 창·스티키 창 동기화)
```

리스트 창에서 제목 변경 → 스티키 창 반영, 스티키 창에서 편집 → 리스트 미리보기 갱신이 이 구조 하나로 해결된다. 동기화 병합(§4-4)도 `SyncService → MemoStore` 경로로 같은 흐름에 합류하므로, UI는 변경이 로컬에서 왔는지 다른 기기에서 왔는지 구분할 필요가 없다.

### 4-4. iCloud 동기화 — 스냅숏 저장/불러오기 (SYNC-*)

**전제: 유료 Apple 개발자 계정 없음.** 유비쿼티 컨테이너와 CloudKit은 iCloud entitlement(유료 계정)가 필요해 사용할 수 없다. 대신 **iCloud Drive의 일반 폴더**(`~/Library/Mobile Documents/com~apple~CloudDocs/MDemo/`)를 동기화 저장소로 쓴다. 이 폴더는 일반 파일 시스템 경로라서 entitlement 없이 읽고 쓸 수 있고, 업로드와 기기 간 전송은 macOS의 iCloud Drive가 알아서 처리한다. 앱이 하는 일은 "로컬 작업 데이터 ↔ 이 폴더" 사이의 push/pull뿐이다.

**동작 모델: 로컬 작업 + 스냅숏 push/pull**

```
push (저장): 로컬 작업 데이터 → iCloud 폴더
  - 수동: 메뉴바·리스트 창의 "지금 iCloud에 저장" (SYNC-02)
  - 자동: 변경 후 디바운스 + 주기(기본 5분, 설정 가능) + 앱 종료 시 (SYNC-04)
  - sync-manifest.json의 modified 비교로 변경된 메모 폴더만 복사 → I/O·메모리 피크 최소화

pull (불러오기): iCloud 폴더 → 로컬 작업 데이터
  - 수동: "iCloud에서 불러오기" (SYNC-03)
  - 자동: 앱 시작 시 + 주기 확인 (SYNC-05)
  - 메모별 병합: iCloud 쪽 modified가 최신이면 로컬 교체, 로컬이 최신이면 유지
```

**병합·충돌 (SYNC-06)**: 메모 단위로 `modified`를 비교한다. 마지막 동기화 이후 양쪽 모두 수정된 메모는 최신본을 채택하되 다른 쪽을 "충돌 사본" 메모로 보존하고 리스트 창에 뱃지를 표시한다 → 사용자가 비교 후 정리. `groups.json`은 합집합 병합. **어떤 경우에도 데이터를 버리지 않는다.** 알람은 각 기기가 로컬 예약하므로 모든 기기에서 울린다(개인용 앱 특성상 허용).

**열린 창 미러링 (SYNC-08) — 대표 시나리오:**

```
맥미니: 새 메모 생성, 플로팅으로 띄움 → open: true 저장 → (주기/수동) push → iCloud
맥북:   (시작/주기/수동) pull → 새 메모 감지, open == true
        → device-state.json에 이 메모의 위치 정보 없음 → 기본 위치·크기로 플로팅 창 생성
        → 맥미니와 "같은 메모가 같은 내용으로" 양쪽에 플로팅됨
        → 이후 맥북에서 옮긴 위치는 맥북에만 기억 (SYNC-07)
맥북에서 창 닫음 → open: false → push → 맥미니가 pull 하는 시점에 함께 닫힘
```

- 반영 시점은 **실시간이 아니라 주기/수동 시점**이다(기본 5분). 즉시 반영이 필요하면 보낸 쪽에서 "지금 저장", 받는 쪽에서 "불러오기"를 실행한다.
- 위치·크기는 기기별(SYNC-07): 맥미니의 모니터 좌표를 맥북 화면에 재현할 수 없으므로 "무엇이 떠 있는가"만 공유한다.
- 미러링이 싫은 경우를 위해 환경설정에 "열림 상태 동기화" 끄기 옵션 제공.

주의 사항:

- 미다운로드(`.icloud` 대체 파일) 항목은 읽기 시 시스템이 자동 다운로드하지만 시간이 걸릴 수 있다 → pull은 항상 백그라운드 큐에서 수행하고 UI를 차단하지 않는다.
- iCloud Drive에 로그인돼 있지 않으면 동기화 메뉴를 비활성화하고 안내 문구를 표시한다.
- iCloud 폴더 접근이 곧 외부 전송은 아니다 — 사용자의 iCloud 계정 안에서만 이동하므로 DAT-01(로컬 우선) 원칙의 예외로 스펙 16장에 명시한다.

**업그레이드 경로 (SYNC-10)**: `SyncService`는 Repository 위의 독립 서비스이므로, 유료 계정을 확보하면 유비쿼티 컨테이너 + NSMetadataQuery 기반 실시간 동기화로 교체할 수 있다. 데이터 구조(메모별 폴더, open/기기 상태 분리, modified 기반 병합)는 그대로 유효하다.

**iOS 확장 (SYNC-11, FUT-03 구체화)** — iOS 앱도 같은 iCloud Drive 폴더에 접근(파일 앱/문서 브라우저 방식)해 동일한 push/pull을 수행한다. 모듈 재사용 매트릭스:

| 모듈 | iOS 재사용 |
|---|---|
| MemoCore | 그대로 사용 (Foundation 전용으로 유지하는 이유) |
| MarkdownEngine | 그대로 사용 |
| Services | Alarm·Backup 대부분 재사용 (조건부 컴파일) |
| EditorKit | 실시간 변환 로직은 MarkdownEngine에 있으므로, UITextView 기반 뷰 어댑터만 새로 작성 |
| StickyWindow | macOS 전용. iOS는 일반 리스트/편집 화면 + 위젯으로 대체 |
| Features (SwiftUI) | 리스트·설정 화면 상당 부분 공유 가능 |

→ 계층 규칙 "MemoCore·MarkdownEngine·Services에 AppKit import 금지"(§7-4)가 iOS 확장의 전제 조건이다.

### 4-5. 메모리 설계 (최우선 비기능 요구)

사용자 확정 우선순위: **메모리 부하 최소화가 이 앱의 제1 요구사항이다.** 원칙은 하나 — *"열려 있지 않은 것은 메모리에 없다."*

| 영역 | 전략 |
|---|---|
| MemoStore | 상주 데이터는 메모당 메타(프론트매터) + 미리보기 텍스트(첫 200자)뿐. 본문 전체는 창이 열린 메모만 보유하고, 창을 닫으면 즉시 해제 |
| 에디터 | TextKit 1 단일 스택, 창당 NSTextView 1개 외 부가 뷰 최소화. 서식은 전부 텍스트 속성으로 표현(서식마다 뷰를 만들지 않음) |
| 이미지 | 원본을 통째로 NSImage로 올리지 않고 **표시 크기에 맞춰 다운샘플링**(CGImageSource 썸네일 API). NSCache에 상한 설정, 창 닫히면 해제. 리스트 미리보기는 이미지를 아예 로드하지 않음 |
| 리스트/설정 창 | 필요할 때 생성하고 닫으면 완전 해제(숨김 상태로 유지 금지 — SwiftUI 뷰 계층은 숨겨도 메모리를 점유). 목록은 lazy 렌더링 |
| 검색 | SQLite 인덱스로 해결 — 검색을 위해 메모 본문을 메모리에 올리는 일이 없다 (SRC-01이 메모 수와 무관하게 동작) |
| 동기화 | push/pull은 백그라운드 큐에서 파일 단위 복사. 전체 데이터를 메모리에 올리는 방식은 ZIP 백업(DAT-04)에만 한정 |
| 스티키 창 다수 | 창마다 완결된 컨트롤러 1개 + 공유 리소스(폰트, 색, 파서)는 싱글턴 — 창 개수에 비례해 늘어나는 것은 텍스트 저장소뿐 |

**측정 게이트**: 마일스톤마다 Instruments(Allocations/Leaks)로 측정하고 기록한다.

- 메뉴바 상주(창 0개): **50MB 이하** (NFR-09)
- 메모 10개 표시: **120MB 이하** (스펙 NFR-02의 150MB보다 엄격한 내부 목표)
- 창을 모두 닫은 뒤: 열려 있던 본문·이미지 메모리가 회수되는지 확인 (NFR-10)

게이트를 초과하면 기능 추가를 멈추고 원인을 잡는다 — 메모리 회귀는 나중에 잡기 어렵다.

---

## 5. 미결정 사항(스펙 15장) 권고안

| 번호 | 질문 | 권고 | 근거 |
|---|---|---|---|
| 1 | 밑줄(Cmd+U) | **기능 제외** (P1에서 뺌) | 마크다운 순수성 유지. 형광(`==`)이 강조 역할을 대체. 필요해지면 렌더 전용으로 추후 추가 |
| 2 | 글자색 | **렌더 전용, P2 유지** | 인라인 HTML은 파일 가독성을 해침. 내보내기 시 소실됨을 UI에 명시 (TXT-01 그대로) |
| 3 | schemaVersion | **넣는다** | §3-2. 마이그레이션 없는 포맷 진화는 불가능 |
| 4 | 첨부 폴더 | **메모별 폴더** | §3-1. 휴지통/삭제/백업이 폴더 단위로 원자화 |
| 5 | 배포 | 당분간 **개인 서명(ad-hoc) 로컬 실행** — 유료 계정 없음. 계정 확보 시 Developer ID + 공증으로 전환 | 스냅숏 동기화(§4-4)는 entitlement가 필요 없어 무료 환경에서 완전 동작 |
| 6 | (신규) 기기 간 동기화 방식 | **iCloud Drive 일반 폴더에 스냅숏 push/pull (수동 + 주기 자동)** | §4-4. 유료 계정 불필요. 실시간 동기화는 계정 확보 시 업그레이드 (SYNC-10) |

이 권고는 개발 착수 전 사용자 확정이 필요하며, 확정 시 이 표를 갱신한다.

---

## 6. 프로젝트 구성

```
MDemo/
├── memo-app-feature-spec.md
├── memo-app-architecture.md        # 이 문서
├── README.md
├── Makefile                        # build / run / test / check / mem
├── Package.swift                   # 앱 타깃 (로컬 패키지들을 조립)
├── Scripts/
│   ├── bundle.sh                   # SwiftPM 산출물 → MDemo.app
│   └── check-layering.sh           # 계층 규칙 · 네트워크 코드 검사
├── docs/
│   ├── measurements.md             # 마일스톤별 메모리·크기 기록
│   └── manual-test-ime.md          # 한글 입력 수동 체크리스트
├── App/
│   ├── Sources/MDemo/              # main, AppDelegate, AppContainer, MenuBar/
│   └── Resources/Info.plist        # LSUIElement 등
└── Packages/                       # 로컬 SPM 패키지 (계층 = §2)
    ├── MemoCore/                   # Sources/ + Tests/
    ├── MarkdownEngine/
    ├── EditorKit/
    ├── StickyWindow/
    ├── Services/
    ├── Features/
    └── TestKit/                    # 테스트 러너 (Xcode 부재 대응)
```

- 다국어(SYS-06)는 P2지만 **String Catalog는 처음부터 사용** — 하드코딩 문자열이 쌓인 뒤 교체하는 비용이 훨씬 크다.
- 샌드박스: 저장 폴더 선택(DAT-02)을 위해 security-scoped bookmark 사용. 네트워크 entitlement 없음 (NFR-07).

---

## 7. 개발 프로세스

### 7-1. 마일스톤 (스펙 14장 로드맵을 실행 단위로 분해)

| 마일스톤 | 내용 | 완료 기준 |
|---|---|---|
| **M0. 골격** ✅ | git init, SPM 패키지 골격, 메뉴바 상주(SYS-01/02), 빈 스티키 창 띄우기 | 완료 (2026-08-26). 측정값은 [docs/measurements.md](docs/measurements.md) |
| **M1. 코어 검증 (리스크 우선)** 🔶 | FrontmatterCodec + FileMemoRepository(원자적 저장) + MemoTextView + **한글 IME 실시간 변환 검증** | 코드·자동 테스트 완료 (2026-08-26). **한글 IME 수동 테스트만 남음** — [docs/manual-test-ime.md](docs/manual-test-ime.md) |
| **M2. 스티키 완성** | 8방향 리사이즈, 위치/크기 기억·복원, 항상 위 토글, 투명도 슬라이더(배경/텍스트 분리+하한), 배경색 프리셋 | 스펙 Phase 1의 창 관련 P0 전부 |
| **M3. 리스트 창** | 목록·그룹·검색(FTS5)·정렬·휴지통 | P0 전체 완료 = **최소 사용 가능 버전**, 이후 실사용 시작 |
| **M4. iCloud 스냅숏 동기화 (Mac↔Mac)** | SyncService: 수동 저장/불러오기 명령, 주기 자동화, 변경분 병합, 충돌 사본, 열린 창 미러링 | 맥미니↔맥북: 한쪽에서 띄운 메모가 다른 쪽 불러오기 시점에 동일하게 플로팅, 충돌 시 데이터 유실 0 |
| **M5. 일상 사용 (P1)** | 전역 단축키, 슬래시 명령, 서식 단축키 확장, 호버 불투명화, 이미지, 알람, 백업/내보내기, 접기, 다중 모니터 보정, 자동 시작 | 스펙 Phase 2 |
| **M6. 완성도 (P2)** | 코드 블록/인용/구분선, 타일 나열, 블러, 단축키 커스터마이징, 다국어 | 스펙 Phase 3 |
| **M7. iOS 앱 (별도 트랙)** | MemoCore/MarkdownEngine 재사용 + UITextView 에디터 + 동일 iCloud Drive 폴더 접근 | iPhone에서 열람/편집, Mac과 동기화 |

M1을 창 완성보다 앞에 두는 이유: 한글 IME × 실시간 변환이 이 앱의 최대 기술 리스크다. 여기서 TextKit 1 접근이 실패하면 에디터 전략을 바꿔야 하므로 가장 먼저 검증한다.

동기화가 M4지만 **동기화 대비 설계는 M1부터 반영한다**: 기기 종속 메타 분리(device-state.json), `open` 필드, 병합의 기준이 되는 `modified` 관리가 저장 계층의 뼈대라서 나중에 끼워 넣으면 저장 경로 전면 수정이 된다. M4는 `SyncService` 하나를 추가하면 완성되는 구조로 만든다. 메모리 게이트(§4-5)는 M1부터 매 마일스톤 측정한다.

### 7-2. 버전 관리 규칙

- **git init을 M0에서 수행** (현재 저장소 아님)
- 브랜치: `main`(항상 빌드 가능) / 기능은 `feat/WIN-07-resize` 형식
- 커밋 메시지: 스펙 ID를 그대로 사용 — `feat(WIN-05): 창 위치/크기 자동 저장`, `fix(NFR-08): 조합 중 변환 보류`
- 마일스톤 완료 시 태그: `v0.1-M1` … `v1.0`(M3 완료 시)

### 7-3. 테스트 전략

| 대상 | 방법 |
|---|---|
| MarkdownEngine | 유닛 테스트 최우선 (변환 규칙별 입력→출력, 직렬화 왕복 `parse(serialize(x)) == x`) |
| MemoCore | FrontmatterCodec 왕복 테스트, 원자적 저장(쓰기 도중 크래시 시뮬레이션), 스키마 마이그레이션 |
| SearchIndex | 더미 1,000개 생성 → 검색 0.3초 측정 (NFR-05) |
| 한글 입력 | 자동화 불가 → 수동 체크리스트 문서(`docs/manual-test-ime.md`) 작성: 조합 중 `**`, `# `, Cmd+B, 슬래시 팝업 각각 확인 |
| SyncService | 병합 시나리오 유닛 테스트: 한쪽만 수정 / 양쪽 수정(충돌 사본 생성) / 신규 / 삭제 / manifest 불일치. 임시 폴더 2개로 두 기기 시뮬레이션 |
| 성능·메모리 | 마일스톤마다 앱 번들 크기, 상주·메모 10개 메모리, 창 닫은 후 회수 측정 (NFR-01/02/09/10, §4-5 게이트) |

### 7-4. 유지보수 규칙 (기능 추가 시 지켜야 할 것)

1. 새 마크다운 문법 = `InputRule` 타입 추가만으로 구현한다. 에디터 본체 수정 금지.
2. 새 창 동작 = Behavior 파일 추가. `StickyPanel` 비대화 금지.
3. 상태 변경은 반드시 `MemoStore`를 거친다. UI에서 Repository 직접 호출 금지.
4. 파일 포맷 변경 = `schemaVersion` 증가 + 마이그레이션 코드 + 왕복 테스트를 한 커밋에 포함.
5. 계층 역방향 의존(예: MemoCore가 AppKit import) 금지 — 패키지 분리가 이를 컴파일 타임에 강제한다.

---

## 8. 다음 단계

1. §5 미결정 권고안 확정 (사용자 승인)
2. M0 착수: git init → 프로젝트/패키지 골격 생성 → 메뉴바 상주 + 빈 스티키 창
3. M1: 한글 IME 리스크 검증
