# Rust 전환(C안) 시작 안내

다른 세션에서 "Rust 전환 시작"을 요청받으면 이 문서부터 읽는다. 결정과 계획은 노션 계획표가 기준이고, 화면은 디자인 캔버스가 기준이다.

## 기준과 목표

- 기준판: **v0.15.0** (main `791a4b2`, 2026-11-26 릴리스). v0.13 구글 드라이브 동기화 · 노션에 보내기 · iCloud 동기화 제거, v0.14 보드 선 정리(길찾기 · 엇갈림 다리 · 단계별 재정렬 · 옮긴 카드만 움직이기), v0.15 메모 창 아래 관계 줄까지 들어간 Swift 판.
- 목표판: **v0.16.0** = 핵심 Rust + 화면 Swift (C안). v0.14 · v0.15의 순수 계산(보드 재정렬 · 선 길찾기 · 엇갈림 점 · 메모 관계)도 Rust 공통(`mdemo-core::board`)으로 옮긴다.
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
| ↳ 화면 지도 | 캔버스 보드 `ScreenMap.dc.html` "v0.16(Rust 전환) 화면 지도" | 화면 12개의 배치 · 문구 · 단축키(바꾸지 않을 것) |
| ↳ 화면 지도 추가 | 캔버스 보드 `ScreenMapV15.dc.html` | ⑬ 보드 선 · ⑭~⑱ 메모 창 관계 줄 · 설정 메뉴 · 접힘 규칙 |
| ↳ 맥 → Windows 대응표 | 캔버스 보드 `PlatformMap.dc.html` | Windows판 화면 계획(P8 다음) |
| ↳ 암호 아이콘 | 캔버스 보드 `LockIcons.dc.html` (B + D안 채택) | 기호 좌표는 `MemoGlyphs.lock` |

캔버스는 Artifact 도구로 `action: "read"`, `path: "project/ScreenMap.dc.html"`처럼 읽는다. 고칠 때는 최신판을 읽은 뒤 그 위에 고쳐 다시 올린다.

## 처음 할 일: P0 기준선

1. 노션 계획표 2장 "먼저 고칠 기존 버그" 4건을 Swift에서 고친다(프론트매터 따옴표 순서 · 줄바꿈, 라벨 토큰 `~` 증식, 영구 삭제의 잠긴 메모 판별, `--data-dir` 시험 실행이 실제 앱 설정 저장소를 씀). v0.15.x로 낸다.
2. 2장 숨은 동작 표를 실행 가능한 테스트로 고정한다. v0.13.0에서 더해진 것도 포함한다.
   - 구글 드라이브 거울: 드라이브 ↔ 거울은 md5(`drive-state.json`), 거울 ↔ 데이터는 동기화 엔진(`sync-state-google.json` · `.hashes.json`).
   - 첫 동기화는 합치기만, 목록 · 내려받기 실패 시 그 회차는 아무것도 지우지 않음, 드라이브 삭제는 영구 삭제.
   - 충돌 사본은 같은 회차에 반대쪽까지 올림(`SyncReport.conflictCopies`).
   - 바뀐 것이 없으면 메모를 다시 쓰지 않음(`MemoStore.updateMeta` · `saveBody`).
3. 골든 파일 생성기와 두 구현(Swift / Rust) 실행기를 만든다. 이 단계에서는 Rust 코드를 쓰지 않는다.
4. 줄 수 · 테스트 수는 v0.12.0 때 값이라 다시 센다(v0.15.0 테스트 347개).
5. v0.14 · v0.15 숨은 동작(보드 재정렬 · 길찾기 · 엇갈림 점 · 끌기 저장 · 메모 관계)도 골든 · 테스트로 고정한다. 규칙은 노션 2장 표.

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

## P1 연결 빌드

- 계층은 Rust 핵심 → MDemoCoreFFI → CoreBridge → MemoCore → 화면 순서다. 화면에서 CoreBridge를 직접 가져오지 않는다.
- 최초 Swift 빌드 전에는 `Scripts/build-core.sh debug`가 필요하다. `make build`와 `make test`는 이를 자동 실행하며, `make release`와 `make dist`는 release 프로필을 사용한다.
- 맥 두 아키텍처의 staticlib를 유니버설 XCFramework로 묶고 앱에는 정적으로 링크한다. cdylib는 UniFFI 메타데이터 추출에만 사용한다.
- 바인딩과 XCFramework는 생성 산출물이다. Rust 소스, Cargo 설정과 잠금 파일, UniFFI 설정, 생성 스크립트, 도구 버전과 프로필이 같으면 재사용한다.
- UniFFI 0.28 생성 코드의 동시성 규칙에 맞춰 CoreBridge만 Swift 5 언어 모드를 사용한다.
- `make test`는 Rust 작업공간과 CoreBridgeTests도 실행한다. `make check`는 Windows MSVC 교차 release 빌드 실패를 그대로 실패로 처리한다.

## P6 구현과 검증 (rust-p6)

앱의 실행 경로는 P7 전까지 Swift 그대로다. Rust `mdemo-sync`에 폴더 동기화, 드라이브 거울 비교, ZIP 백업을 추가했다. DriveApi는 list · download · upload · update · create_folder · delete만 정의하며 HTTP · OAuth · 토큰은 구현하지 않는다. 기존에 사용 중인 serde · serde_json · mdemo-crypto를 재사용했고 새 외부 크레이트는 추가하지 않았다.

### 변경 파일과 이유

- `core/crates/mdemo-sync/src/{engine,state,drive,backup,files,md5,fake,tests,lib}.rs`, 해당 Cargo.toml: Swift 규칙의 Rust 구현, 주입 가능한 시계 · ID · 열쇠 저장소, 네트워크 없는 가짜 드라이브, 폴더 교체와 재시도 시험.
- `core/crates/mdemo-core/src/store/repository.rs`: 잠긴 메모 폴더의 백업 제외 표시 함수를 공개해 백업 복원에서도 재사용.
- `core/crates/mdemo-golden/{Cargo.toml,src/main.rs,src/sync_step.rs}`, `core/Cargo.lock`: 상태 세 파일 생성과 시험 연산 실행, 기존 작업공간 크레이트 연결.
- `Packages/Golden/Sources/mdemo-golden/{main,SyncStep,FakeDrive}.swift`: Swift 시험 명령과 ServicesTests 가짜 드라이브 소스 공유. FakeDrive.swift는 공유 소스로 향하는 상대 심볼릭 링크다.
- `Packages/Services/Tests/ServicesTests/{main,FakeDrive}.swift`: 기존 가짜 드라이브를 별도 파일로 옮기고 고정 시각 · 상태 직렬화 · 요청별 실패 주입 추가.
- `Packages/Services/Sources/Services/SyncService.swift`, `GoogleDrive/DriveMirrorSync.swift`: 시험에서 충돌 ID 생성기를 주입하도록 열었다. 앱의 기본 ID 생성기와 동작은 같다.
- `Packages/MemoCore/Tests/MemoCoreTests/main.swift`: macOS 27의 Foundation 조회 불일치 때문에 백업 제외의 실제 디스크 속성 목록을 검증한다. 앱의 저장 코드는 유지했다.
- `Scripts/{sync-check,backup-check}.{sh,py}`, `golden-build-swift.sh`, `golden-run-swift.sh`, `golden/sync-scenarios/`: 두 기기 교차 검사, 상태 쌍 왕복, 백업 ZIP 교차 검사와 Swift 시험 도구의 한 번 빌드.
- `Scripts/{golden-check,test,check-core-windows}.sh`, `Makefile`: 골든 미이전 목록 제거, 기본 검사와 전체 검사 연결, Windows 빌드에 mdemo-sync 포함.
- `golden/README.md`, `docs/hidden-behaviors.md`, 이 문서: 검사 계약, 새로 확인한 규칙, 구현 결과 기록.

### 시나리오 결과

모든 행에서 SS · RR · SR · RS가 각 단계의 두 데이터 · 거울 폴더, 드라이브 파일 · 요청 기록, 상태 파일과 보고서까지 일치했다.

| 번호 | 검사 | 결과 |
|---|---|---|
| 1 | 첫 동기화 합치기, 삭제 요청 0 | 4조합 통과 |
| 2 | 한쪽 수정 후 다른 기기 받기 | 4조합 통과 |
| 3 | 양쪽 수정, 충돌 사본의 같은 회차 드라이브 전파 | 4조합 통과 |
| 4 | 휴지통, 파기 장부와 영구 삭제 요청 전파 | 4조합 통과 |
| 5 | 목록 · 내려받기 실패, 삭제 예정 파일도 그대로 보존 | 4조합 통과 |
| 6 | 잠김 · 로컬 전용 메모의 올리기 요청 없음 | 4조합 통과 |
| 7 | 무변경 memo.md 수정 시각 보존, ±0.0004/0.0005/0.0006초 판단 | 4조합 통과 |
| 8 | 첨부 이미지 256바이트와 한글 경로 보존 | 4조합 통과 |
| 전체 9~12 | 실패한 올리기 · 삭제 재시도, push/pull, 외부 편집, 두 번째 내려받기 실패 | 각각 4조합 통과 |

상태 쌍 S→R · R→S는 각각 20개 ID의 모든 날짜와 지문을 복원했다. 골든은 양쪽 17개 파일 바이트 일치, Rust 단위 시험은 11개 통과다. 백업 ZIP은 풀린 트리 · 내용 일치, SS · RR · SR · RS 가져오기, 파기 ID 거부, 교체 시 기존 암호문 · 백업 제외 표시 보존을 확인했다.

`make test`, `make check`, `make sync-full`을 실행해 통과했다. macOS arm64 실행과 x86_64 빌드, Windows x86_64 MSVC 교차 release 빌드를 확인했다. 검증 환경의 제한 때문에 Swift의 sandbox 해제 · native 빌드 설정과 Cargo 오프라인 설정은 실행 프로세스에서만 주입했다. Windows SDK 캐시도 시험용 build 폴더의 복사본을 사용했다. 이 설정들을 빌드 스크립트에 고정하지 않았다.

### Windows 폴더 교체와 남은 확인

새 폴더를 같은 부모의 `.<id>.tmp`에 만든다. 기존 폴더를 `.<id>.old`로 옮기고 임시 폴더를 원래 자리에 옮긴 뒤 복구본을 지운다. 임시 폴더 이동이 실패하면 복구본을 원래 이름으로 되돌린다. 되돌리기도 실패하면 복구본을 남기고 두 오류를 함께 반환한다. 남은 복구본을 덮어쓰지 않는다. 이 공통 함수의 실패 복구 · 기존 복구본 보존은 macOS에서 실행 시험했다. macOS 실제 교체는 `renamex_np(RENAME_SWAP)`의 원자적 이름 교환이다.

Windows 실기 실행과 플랫폼 HTTP 연결은 각각 P8 · P7 이후 범위다. 이번에는 노션 원문을 읽을 수 있는 연결 도구가 없어 저장소 문서와 Swift 원본, 요청에 적힌 계획 규칙을 기준으로 구현했다. Rust는 링크와 안전하지 않은 ZIP 경로를 거부하므로 그 입력까지 Swift ditto와 같은 동작이라고 주장하지 않는다. 단순 파일 소실 시 엔진이 다시 보내는 기존 동작을 포함한 세부 사항은 `docs/hidden-behaviors.md`에 기록했다. 커밋 · 푸시 · 브랜치 변경은 하지 않았다.

## P7 1단계 저장소 그림자 실행

실제 쓰기는 Swift에 유지하고 Rust는 읽기 또는 회차별 복제본에서만 비교한다. `CoreShadow.wrap` 공개 함수 하나로 AppContainer에 연결했으며 기본 꺼짐이다. `App/Resources/Info.plist`의 `MDemoRustShadow`를 true로 하거나 `--rust-shadow`로 켠다. 시험 실행은 `--data-dir=<시험 폴더>`와 함께 사용한다. 앱 실행 검수는 이번 작업에서 하지 않는다.

FFI의 `ShadowBridge`, MemoCore의 `ShadowMemoRepository`, `Scripts/shadow-report.sh`를 추가했다. 정규 문자열, 개인정보 기록 제한, 복제 범위와 엄격한 시각 비교의 한계는 [숨은 동작](hidden-behaviors.md)의 P7 절에 정의한다. `FileMemoRepository`는 Swift 구조체이므로 꺼짐 시험은 객체 동일성 대신 원래 구체 타입과 rootDirectory, 주입한 쓰기 훅의 보존을 확인한다.

원문 노션 계획표는 이 환경의 도구로 열 수 없었다. 사용자 요청의 3장 6번·4장 P7 규칙과 저장소 문서, Swift 구현을 기준으로 작업했다. 노션 원문 일치 검수는 남아 있다. 커밋·푸시·브랜치 변경은 하지 않는다.

변경 파일은 다음과 같다.

- `core/crates/mdemo-ffi/src/shadow.rs`, `src/lib.rs`, `Cargo.toml`, `core/Cargo.lock`: 해시·요약·복제본 연산의 UniFFI 경계. 기존 sha2·serde_json 의존성만 연결했다.
- `core/crates/mdemo-core/src/store/repository.rs`: 디렉터리 생성 없는 읽기 전용 저장소 생성 경로.
- `Packages/CoreBridge/Sources/CoreBridge/ShadowBridge.swift`: 생성 바인딩의 얇은 Swift 래퍼.
- `Packages/MemoCore/Sources/MemoCore/Storage/ShadowMemoRepository.swift`: 실제 Swift 위임, 제한된 복제와 직렬 비교, 개인정보 없는 JSONL·누적 요약, CoreShadow 켜기 함수.
- `App/Sources/MDemo/AppContainer.swift`, `App/Resources/Info.plist`: MemoCore 공개 함수로 조립하고 기본 Bool을 false로 선언.
- `Packages/MemoCore/Tests/MemoCoreTests/ShadowTests.swift`, `main.swift`: 격리된 그림자 시험과 단독 실행 인자.
- `Scripts/shadow-report.sh`: 한국어 요약·차이 목록과 종료 코드.
- `docs/hidden-behaviors.md`, `docs/measurements.md`, 이 문서: 정규 문자열 계약, 측정과 남은 차이 기록.

검증은 `make test`(Swift 370개, Rust 161개 통과와 기존 장시간 시험 1개 생략, 양쪽 골든 17개, 저장소·암호·동기화·백업 교차 검사), `make check`(계층과 Windows MSVC release), 앱의 macOS 빌드까지 통과했다. 후속 잠금 판별·용량 예약 보강 후에는 그림자 시험 8개를 다시 통과했다. 보고서 스크립트는 차이 없음·차이 있음·기록 누락의 종료 코드 0·1·2를 확인했다. 실제 앱은 실행하지 않았다. 측정값과 목표를 넘긴 회차는 [측정 기록](measurements.md)의 P7 절에 함께 기록했다. 자동 mtime 차이를 숨기지 않으므로 이 결과를 쓰기 연산의 차이 0 승인으로 해석하면 안 된다.

## P7 2-a 실제 저장소 선택

기본 저장소는 아직 Swift다. `MDemoRustStorage` Bool 또는 `--rust-storage`를 켜면 `CoreStorage.make(root:keychain:)`가 `RustMemoRepository`를 만든다. 이 경로에는 그림자를 붙이지 않는다. 꺼져 있으면 기존 `CoreShadow.wrap(FileMemoRepository)`를 쓴다. AppContainer는 MemoCore의 조립 함수만 호출하며 화면과 MemoStore는 바꾸지 않았다.

### 변경 파일과 이유

- `core/crates/mdemo-ffi/src/repository.rs`, `src/lib.rs`, `Cargo.toml`, `core/Cargo.lock`: CoreRepository 객체, 메타데이터 · 문서 · 요약 · 보드 레코드, 구분 가능한 오류, Swift 열쇠 저장소 콜백을 추가했다. 새 외부 크레이트 없이 기존 내부 mdemo-crypto를 연결했다.
- `core/crates/mdemo-core/src/store/{repository,tests}.rs`: 첨부를 포함한 폴더 복제와 저장 실패 시 사본 정리, 기존 사본 보존 시험을 추가했다.
- `Packages/MemoCore/Sources/MemoCore/Storage/{RustMemoRepository,CoreStorage}.swift`: 레코드 변환과 키체인 어댑터, Foundation 검색 판정, 목록 동률 순서 복원, 플래그 선택을 구현했다. 생성 CoreBridge 코드는 직접 고치지 않았다.
- `App/Sources/MDemo/AppContainer.swift`, `App/Resources/Info.plist`: 조립 함수를 연결하고 MDemoRustStorage 기본값 false를 선언했다.
- `Packages/MemoCore/Tests/MemoCoreTests/{main,ShadowTests}.swift`, `Scripts/test.sh`: 공통 저장소 팩토리로 기존 저장소 · MemoStore 시험을 두 번 실행한다. 레코드 모든 필드와 모르는 라벨 꼬리, Cocoa 파일 없음, 플래그 선택 시험도 공통으로 실행한다.
- `Packages/MemoCore/Sources/MemoCore/Storage/ShadowMemoRepository.swift`, `Packages/Golden/Sources/mdemo-golden/{main,ShadowExercise}.swift`, `Scripts/shadow-exercise.sh`: `--rust`에서는 Rust를 실제 구현으로 쓰고 Swift를 복제본 비교 구현으로 쓴다. 기존 용량 · 대기열 · 잠긴 메모 생략 · 개인정보 없는 기록 규칙을 공유한다.

### 시험 범위

MemoCore 공통 90개를 Swift와 Rust 각각 실행한다. Swift 전용은 10개다.

| 개수 | 사례와 이유 |
|---:|---|
| 2 | 암호 메모 쓰기 가로채기와 본문 저장 실패 주입. Swift `beforeMemoWrite`의 임의 Swift 오류와 실제 직전 바이트 검사를 Rust 원자적 쓰기에 주입하는 콜백은 이번 FFI에 추가하지 않았다. |
| 8 | 기존 정방향 그림자 장식자의 복제 · 손상 · 잠김 생략 · 경쟁 · 용량 · 시각 · 꺼짐 타입 · 동기 시간 검사. Swift 원본과 시험 훅의 계약 자체를 검증하므로 Swift에서만 실행한다. 역방향은 별도 장시간 검사로 검증한다. |

시각 시험은 필요할 때 Rust `setClockForTesting`을 쓸 수 있다. 앱은 호출하지 않으며 기본은 시스템 시계다. 암호 생성 · 해제 · 암호 변경 · 파기는 Swift LockCrypto와 MemoStore를 그대로 쓰면서 저장소 경계만 바꿔 검사한다. 시험 데이터와 열쇠는 임시 폴더와 메모리 키체인뿐이다.

### 다음 단계에 남긴 직접 생성

| 파일 | 위치와 용도 |
|---|---|
| `Packages/Services/Sources/Services/SyncService.swift` | applyPrivacy의 privacyRepository. 잠긴 메모 요약을 읽어 로컬 전용 집합에 합친다. |
| `Packages/Services/Sources/Services/BackupService.swift` | replaceExisting 가져오기에서 기존 잠긴 메모의 목록을 읽어 암호문 폴더를 보존한다. |

두 Services 경로는 이번에 바꾸지 않았다. Swift 제목 정렬과 Foundation 검색 판정도 그대로다. 네트워크 금지 조건에 따라 노션에 접근하지 않았으며 요청에 제공된 1장 · 3장 2번 규칙과 저장소 문서를 기준으로 작업했다. 앱 실행 검수와 실제 데이터 검수는 지휘자 범위다. 커밋 · 푸시 · 브랜치 변경은 하지 않는다.

### 검증 결과

최종 전체 러너에서 MemoCore `[Swift]` 100개, `[Rust]` 90개가 통과했다. Swift 전용 10개는 위 표의 이유로 별도 표시했다. 전체 Swift 러너는 두 MemoCore 실행을 포함해 463개, Rust 작업공간은 163개 통과와 기존 장시간 시험 1개 생략이다. 골든은 양쪽 각각 17개 바이트 일치, 저장소 시나리오 6개와 암호 시나리오 7개의 교차 검사, 동기화 · 백업 교차 검사도 통과했다. `make check`의 계층 검사와 Windows x86_64 MSVC 교차 release 빌드, macOS arm64 · x86_64 FFI 빌드도 통과했다.

일반 실행은 이 환경의 중첩 sandbox 제한과 홈 cargo-xwin 캐시 쓰기 금지로 막혔다. 최종 `make test`는 호출 프로세스에만 SwiftPM sandbox 해제와 native 빌드 선택 함수를 전달했고, `make check`는 기존 `build/p6-xwin-cache`를 `XWIN_CACHE_DIR`로 지정했다. 제품 스크립트에는 이 우회 옵션을 추가하지 않았다. 중간 EditorKit 엔터 시험의 일시 실패는 코드 변경 없이 단독 80개와 최종 전체 실행 80개에서 모두 재통과했다. 실제 홈 데이터 · 키체인 · 네트워크와 앱 실행은 검증에 사용하지 않았다.
