# Swift와 Rust 비교 규약

`make golden`은 `inputs/`의 고정 입력을 Swift 구현으로 처리해 `expected/`를 갱신한다. 갱신한 결과는 반드시 검토한다. `make test`는 기준을 갱신하지 않고 Swift와 Rust 결과를 바이트 비교한다.

```sh
make golden
Scripts/golden-check.sh swift
Scripts/golden-check.sh rust
```

Rust 비교는 `mdemo-golden`을 오프라인 빌드한 뒤 실행한다. 메모와 보드, 그룹, 기기 상태, 두 장부는 바이트가 같아야 통과한다. 아직 옮기지 않은 보드 계산, 관계 계산, 동기화 상태 두 파일, 드라이브 상태는 `미이전: 파일명`으로 표시한다. 목록은 `Scripts/golden-check.sh`의 `RUST_PENDING` 한 곳에 둔다. 알 수 없는 구현과 잘못된 인자는 종료 코드 2로 실패한다.

## CLI 계약

두 구현 모두 다음 위치 인자 두 개를 받는다. 입력은 읽기 전용이다. 출력 폴더는 없으면 생성하며, 호출자는 비어 있는 새 폴더를 제공한다. 성공 시 0, 처리 실패 시 0 이외의 종료 코드를 반환하고 표준 오류에 이유를 쓴다.

```text
mdemo-golden <입력 폴더 절대 경로> <출력 폴더 절대 경로>
```

현재 Swift 실행은 `Scripts/golden-run-swift.sh <입력> <출력>`으로 한다. 별도 최상위 패키지 `Packages/Golden`이 MemoCore, Services, Features, StickyWindow를 조합한다. 기존 내부 계산과 상태 저장기에 접근하므로 디버그 빌드의 `@testable`을 사용한다. 앱, 창, 실제 키체인, API는 실행하지 않는다. Rust CLI는 이번에 이관한 파일만 출력하며 Swift 앱은 계속 Swift 구현을 사용한다.

## 고정 입력과 출력

| 입력 | 처리와 출력 |
|---|---|
| `memos/memo.md` | 선 10종, 인코딩된 라벨, 모르는 토큰과 줄, 따옴표, 역슬래시, 줄바꿈 값을 읽고 같은 상대 경로로 기록 |
| `memos/legacy.md` | v1 메타데이터를 현재 스키마로 읽고 기록 |
| `memos/crlf.md` | CRLF는 LF로 바꾸고 본문의 단독 CR은 보존 |
| `memos/locked.md` | 가짜 잠금 앞머리와 가짜 암호문 보존, 복호화 없음 |
| `memos/alpha.md` | NaN과 알파 하한의 현재 동작 |
| `board.json`, `groups.json`, `device-state.json` | 실제 저장기로 읽고 기록 |
| `destroyed.json`, `local-only.json` | 장부로 읽고 정렬, 중복 제거 후 기록 |
| `sync-state-google.json`, `sync-state-google.hashes.json` | 실제 동기화 상태 읽기와 쓰기. 날짜 불일치 지문은 버림 |
| `drive-state.json` | 실제 드라이브 상태 읽기와 쓰기. 네트워크 호출은 실패하는 가짜 API만 주입 |
| `search-cases.json` | (본문, 검색어) 쌍의 일치 여부를 `search-results.json`에 `[[MemoSearch.matches, searchBodies], ...]` 한 줄로 기록. 앞은 본문을 미리보기로 넣은 요약의 제목 · 미리보기 · 그룹 판정, 뒤는 파일에 저장한 본문만의 판정(Swift는 실제 `MemoSearch.matches`와 `FileMemoRepository.searchBodies`) |
| `markdown-cases.json` | 마크다운 엔진 사례(문서 · 한 줄 · 인라인 · 표 · 붙여넣기 · OCR 줄 목록 · 이미지 이름 · 슬래시 검색 · 입력 규칙 · 이미지 줄 · 번호 표식)를 엔진에 그대로 넣고 `markdown-results.json`에 키를 정렬한 한 줄 JSON으로 기록. 문자열은 따옴표 · 역슬래시 · 0x20 미만 제어 문자만 이스케이프하고 나머지는 UTF-8 그대로. 블록은 `{kind, ...}`, 구간은 `{text, styles(비트), textColor, highlightColor}` |
| `board-calculations.json` | 여러 무리, 순환, 외톨이 재정렬, 직선, 장애물, 같은 변의 여러 선 점열과 엇갈림을 `board-calculations.json`에 기록. 바로 이웃, 두 단계, 중복, 최대 12, 설정 끔은 `relations.json`에 기록 |

입력의 모든 ID와 드라이브 식별자는 가짜다. 날짜는 고정되어 있고 ID 생성과 현재 시각을 쓰는 경로는 호출하지 않는다. 생성기의 작업 폴더는 임시 폴더이고 키체인은 메모리 대역이다. 스크립트는 Foundation 설정 홈도 임시 폴더로 분리한다.

계산 결과 JSON은 객체 키를 정렬하고 모든 숫자를 소수 여섯 자리로 출력한다. 저장 파일은 기존 저장기의 서식을 따른다. 단, 두 동기화 상태 파일은 원래 객체 키 순서가 비결정적이므로 읽고 쓴 뒤 JSON 객체 키를 정렬해 비교한다. 이 두 파일은 기존의 압축 JSON 형태를 유지한다. 앱 저장기를 수정한 것은 아니다. 비결정적 키 순서를 바이트 계약으로 삼을 수 없어서 둔 골든의 정규화 규칙이다.

보드 JSON의 실제 저장기는 `prettyPrinted + sortedKeys`다. 그룹 JSON은 배열이므로 키 정렬 대상이 없고 배열 순서를 유지한다. 기기 상태는 `prettyPrinted + sortedKeys`, 드라이브 상태는 압축 JSON과 `sortedKeys`다. JSON의 `"key" : value` 공백과 `\/`는 저장기 출력 그대로 비교한다.

비교기는 누락 파일과 추가 파일도 실패로 처리하고, 내용 차이는 파일명과 첫 차이 행의 원시 바이트를 표시한다. 마지막 줄바꿈 차이도 검출한다. 입력을 추가하면 생성기도 해당 입력을 처리하도록 함께 수정한다.

## 차분 퍼즈

```sh
make fuzz                       # 메모 2000개, 기본 시드 20261126
make fuzz N=100000 SEED=42
Scripts/fuzz-diff.sh 2000 42
```

`mdemo-fuzzgen`은 고정 가능한 SplitMix64 시드로 메모와 보드, 그룹을 만든다. 500개씩 한 폴더에 넣어 두 CLI를 호출한다. 선 10종, 잘못된 퍼센트와 UTF-8 라벨, 모르는 꼬리, 결합 문자와 이모지, 따옴표와 역슬래시, LF와 CRLF, 날짜 경계, 큰 Double과 음수 0을 포함한다. 생성기는 원문을 직접 만들며 Rust 파서의 결과를 입력으로 재사용하지 않는다. 나머지 입력은 고정 골든을 복사한다.

차이가 나거나 CLI가 실패하면 `golden/fuzz-failures/`에 입력, 두 출력과 로그를 남기고 실패한다. 출력에는 건수, 경과 초, 차이 파일 수와 시드를 표시한다. 기본 시드도 명시하므로 그대로 재현할 수 있다. 보관한 최소 재현 입력은 해당 폴더 README를 참고한다.

Rust는 캐시에 있는 크레이트만 사용한다. 라벨 경계는 `unicode-segmentation`, Swift의 문자열 동등 비교는 Unicode 17.0 정규 분해 표를 사용한다. `unicode-normalization`은 캐시에 없어 별도 크레이트 없이 정규 분해를 구현했다. 표 재생성은 Unicode 17.0 데이터를 가진 Python에서 `python3 Scripts/generate-unicode-tables.py`로 한다.

## 마크다운 엔진 비교 (P5)

`inputs/markdown-cases.json`은 열한 갈래(`documents` `lines` `inlines` `tables` `pastes` `ocr` `imageNames` `slash` `inputRules` `images` `markers`)에 각 80개 이상, 모두 1,280여 건이다. 한글, 이모지, 결합 문자, CRLF, 탭, 중첩 목록, 깨진 표, 색 태그, 정규 동치 글자(U+1FEF 등)를 포함한다. Swift(`Packages/Golden/.../MarkdownCases.swift`)와 Rust(`mdemo-golden/src/markdown_cases.rs`)가 같은 `markdown-results.json`을 내야 통과한다. 차분 퍼즈는 `mdemo-fuzzgen`이 배치마다 이 파일을 무작위로 다시 만든다(문서 · 한 줄 · 인라인 · 붙여넣기 · 표 · 입력 규칙 · 이미지 문법은 건수만큼, OCR · 이미지 이름 · 슬래시 · 표식은 절반). 짝이 맞는 중첩 서식, 닫는 기호 누락, 색 태그 변형, 앞머리 직후 커서를 자주 만든다. 마크다운 쪽은 로케일 의존 판정이 없어 검색과 달리 차이를 허용하지 않는다. 읽은 규칙은 `docs/hidden-behaviors.md`의 P5 항목을 본다.

## 데이터 폴더 시나리오 (P3)

`golden/scenarios/*.json`은 연산 목록이다. 같은 목록을 Swift(`FileMemoRepository` + `MemoStore`)와 Rust(`mdemo-core::store`)로 빈 임시 폴더에서 실행하고 결과 폴더를 비교한다.

```sh
Scripts/scenario-check.sh      # make test에 포함
Scripts/golden-run-swift.sh scenario golden/scenarios/lifecycle.json <빈 폴더>
core/target/debug/mdemo-golden scenario golden/scenarios/lifecycle.json <빈 폴더>
```

- 연산: `create{id,time,colorHex?,group?}`, `saveBody{id,time,body}`, `updateMeta{id,time,colorHex?,group?,title?,isOpen?,isPinned?}`(키가 있으면 설정, `null`은 비움), `link{from,to,kind,time}`, `moveToTrash{id,time}`, `restore{id}`, `deletePermanently{id,time}`, `emptyTrash{now,days?=30}`, `emptyTrashAll`, `addAttachment{id,name,bytes(base64)}`, `removeAttachment{id,name}`, `pruneUnusedAttachments{now,days?=1}`, `setBoardPlacements{placements}`, `setGroups{groups}`, `ledgerInsert{name,id}`, `touch{path,time}`(데이터 폴더 안 파일 · 폴더의 수정 시각 지정).
- 시각은 ISO 8601 문자열이고 `time`이 있는 연산은 그 시각으로 시계를 옮긴다. ID는 `create`의 `id`를 쓴다. 시각과 ID는 Swift에서 `FileMemoRepository.clock`, `MemoStore.clock` · `generateID`(기본값은 실제 시각과 새 ULID라 앱 동작은 같다)로, Rust에서 `Clock` · `IdSource`로 주입한다.
- 비교: 폴더와 파일 목록, 파일 바이트, 그리고 `trash/<ID>` 폴더와 시나리오의 `mtimeCheck`에 적은 경로의 수정 시각(밀리초). "다시 쓰지 않음"은 `touch`로 수정 시각을 과거로 돌려 두고 같은 값을 저장한 뒤 시각이 그대로인지 본다. 차이는 파일별로 출력하고 실패한다.
- 시나리오: `lifecycle`(수명 주기), `trash-30days`(휴지통과 30일 비우기), `attachments`(첨부), `no-rewrite`(다시 쓰지 않음), `destroyed-ledger`(파기 장부), `trash-collision`(같은 ID 충돌).
- 복제와 실제 이미지 저장은 시나리오에 없다(플랫폼 몫). 잠긴 메모와 안전 삭제는 아래 암호 시나리오에서 다룬다.

## 암호 메모 교차 시나리오 (P4)

`golden/lock-scenarios/*.json`(전체 검사 전용은 `full/`)은 `scenario`와 같은 연산에 암호 연산을 더한 목록이다. 실제 `MemoStore` + 데이터 폴더 안 `keychain.json`(시험용 가짜 키체인, 실제 키체인에는 닿지 않는다)을 쓴다.

```sh
Scripts/lock-check.sh          # 빠른 시나리오 7개, make test에 포함
Scripts/lock-check.sh full     # 열 번 틀림 포함 전체 (make lock-full)
Scripts/golden-run-swift.sh lock golden/lock-scenarios/01-cross-open.json <빈 폴더> [--phase N]
core/target/debug/mdemo-golden lock golden/lock-scenarios/01-cross-open.json <빈 폴더> [--phase N]
```

- 연산(추가분): `createLocked{id,source?,password,expect?}`, `unlock{id,password,expect?}`, `relock{id}`, `changePassword{id,password}`, `moveToPlain{id,newId}`, `destroy{id}`, `saveLockedBody{id,body,expect?}`(`ok`/`refused`), `loadTrash`, `setFailures{id,keychain?,header?,rawKeychain?}`, `corruptBody{id}`, `flipByte{path,offset}`, `writeFile{path,text}`, `assertBody`, `assertAttachment{id,name,bytes}`, `assertFailures{id,keychain?,header?}`, `assertExists{path,exists?}`. `expect`는 `ok`나 오류 종류(`invalidPassword` `missingKey` `wrongPassword` `damaged` `locked` `destroyed` `keyStore` `authentication` `incorrectSize` `other`)다.
- 반복 횟수는 두 실행기 모두 200만(최소값)으로 고정한다. 암호문 · 솔트 · 감싼 열쇠는 무작위라 바이트 대신 크기만 비교하고, 상대 구현이 열 수 있는지는 `assert*` 연산이 평문을 비교해 확인한다.
- 연산의 `phase`(기본 1)로 단계를 끊어 구현을 바꿔 가며 같은 폴더를 이어 실행한다(SS, RR, SR, RS, 3단계 이상이면 SRS, RSR). 모든 조합의 연산별 결과 기록과 정규화한 최종 상태(파일 바이트, `trash/<ID>` 폴더 시각, 잠긴 메모 폴더의 백업 제외 표시, 키체인 상태)가 같아야 통과한다.
- 시나리오: `01-cross-open`(서로의 암호 메모 열기), `02-wrong-password`(횟수), `03-damaged`(손상), `04-tenth-failure`(10번째 파기), `05-failure-max`(max 규칙), `06-change-password-and-plain`(암호 바꾸기 · 일반 메모로 옮기기), `07-secure-delete`(영구 삭제 · 휴지통 비우기), `full/04b-ten-attempts`(처음부터 열 번).

## 본문 검색 일치 비교

`inputs/search-cases.json`(한글 자모 · 완성형, NFC/NFD, 대소문자 접기, 터키어 i, 결합 문자, 이모지 · ZWJ, 전각 · 반각, 숫자 모양, 빈 검색어, 공백, 줄바꿈 등 480여 쌍)은 두 구현이 같은 `search-results.json`을 내야 통과한다. 차분 퍼즈(`Scripts/fuzz-diff.sh`)는 무작위 쌍도 같은 방식으로 비교한다. Rust 규칙은 Swift의 `localizedCaseInsensitiveContains`를 관찰해 맞춘 근사이며, 규칙 목록은 `core/crates/mdemo-core/src/store/search.rs` 머리말에 있다.

- 알려진 한계: 결합 기호 · 한글 자모 · ZWJ · 키캡이 겹치는 아주 드문 조합에서는 퍼즈가 수천 건에 한두 건 차이를 낸다(기본 시드 20261126의 5000건은 차이 0건). 로케일은 실행 환경의 것으로만 확인했다.
