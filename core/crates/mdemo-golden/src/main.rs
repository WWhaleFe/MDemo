use mdemo_core::{board_layout::BoardLayout, device_state, frontmatter, groups, json, ledger};
mod lock_scenario;
mod markdown_cases;
mod scenario;
mod search_cases;
mod sync_step;
use std::{env, error::Error, fs, path::Path};
fn run(input: &Path, output: &Path) -> Result<(), Box<dyn Error>> {
    fs::create_dir_all(output.join("memos"))?;
    for entry in fs::read_dir(input.join("memos"))? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|s| s == "md") {
            let d = frontmatter::decode(&fs::read_to_string(&path)?)
                .map_err(|e| format!("{}: {e}", path.display()))?;
            fs::write(
                output.join("memos").join(entry.file_name()),
                frontmatter::encode(&d),
            )?;
        }
    }
    let board: BoardLayout = serde_json::from_slice(&fs::read(input.join("board.json"))?)?;
    fs::write(output.join("board.json"), json::encode(&board, true, true)?)?;
    let groups: Vec<String> = serde_json::from_slice(&fs::read(input.join("groups.json"))?)?;
    fs::write(output.join("groups.json"), groups::encode(&groups)?)?;
    let states = device_state::decode(&fs::read(input.join("device-state.json"))?);
    fs::write(
        output.join("device-state.json"),
        json::encode(&states, true, true)?,
    )?;
    for name in ["destroyed.json", "local-only.json"] {
        let ids = ledger::decode(&fs::read(input.join(name))?)?;
        fs::write(output.join(name), json::encode(&ids, false, true)?)?;
    }
    let state = mdemo_sync::state::SyncState::load(&input.join("sync-state-google.json"));
    state.try_save(&output.join("sync-state-google.json"))?;
    let drive = mdemo_sync::drive::DriveState::load(&input.join("drive-state.json"));
    drive.save(&output.join("drive-state.json"));
    // 보드 계산 두 파일(v0.14 재정렬 · 길찾기 · 엇갈림, v0.15 관계)
    let calc = input.join("board-calculations.json");
    fs::write(
        output.join("board-calculations.json"),
        mdemo_core::board::golden::board_calculations(&calc)?,
    )?;
    fs::write(
        output.join("relations.json"),
        mdemo_core::board::golden::relations(&calc)?,
    )?;
    // 본문 검색 일치(입력에 search-cases.json이 있을 때). 저장소 시험은 따로 둔 폴더에서 한다.
    let cases = input.join("search-cases.json");
    if cases.exists() {
        let root = output.join(".search-root");
        let text = search_cases::run(&cases, &root)?;
        fs::remove_dir_all(&root)?;
        fs::write(output.join("search-results.json"), text)?;
    }
    // 마크다운 엔진 고정 사례(P5). 입력에 markdown-cases.json이 있을 때만 만든다.
    let markdown = input.join("markdown-cases.json");
    if markdown.exists() {
        fs::write(
            output.join("markdown-results.json"),
            markdown_cases::run(&markdown)?,
        )?;
    }
    Ok(())
}
fn main() {
    let args: Vec<_> = env::args().collect();
    if args.len() == 4 && args[1] == "sync-step" {
        if let Err(e) = sync_step::run(Path::new(&args[2]), Path::new(&args[3])) {
            eprintln!("동기화 시험 실패: {e}");
            std::process::exit(1);
        }
        return;
    }
    if args.len() == 4 && args[1] == "scenario" {
        if let Err(e) = scenario::run(Path::new(&args[2]), Path::new(&args[3])) {
            eprintln!("시나리오 실패: {e}");
            std::process::exit(1)
        }
        return;
    }
    // lock <시나리오.json> <데이터 폴더> [--phase N]: 암호 메모 시나리오 (P4)
    if args.len() >= 4 && args[1] == "lock" {
        let phase = match args.len() {
            4 => None,
            6 if args[4] == "--phase" => args[5].parse::<i64>().ok(),
            _ => {
                eprintln!("사용법: mdemo-golden lock <시나리오.json> <데이터 폴더> [--phase N]");
                std::process::exit(2)
            }
        };
        if let Err(e) = lock_scenario::run(Path::new(&args[2]), Path::new(&args[3]), phase) {
            eprintln!("시나리오 실패: {e}");
            std::process::exit(1)
        }
        return;
    }
    if args.len() != 3 {
        eprintln!("사용법: mdemo-golden <입력> <출력> | mdemo-golden scenario <시나리오.json> <데이터 폴더> | mdemo-golden lock <시나리오.json> <데이터 폴더> [--phase N]");
        std::process::exit(2)
    }
    if let Err(e) = run(Path::new(&args[1]), Path::new(&args[2])) {
        eprintln!("골든 생성 실패: {e}");
        std::process::exit(1)
    }
}
