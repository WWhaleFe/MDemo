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
