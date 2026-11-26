use mdemo_core::{board_layout::BoardLayout, device_state, frontmatter, groups, json, ledger};
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
    Ok(())
}
fn main() {
    let args: Vec<_> = env::args().collect();
    if args.len() != 3 {
        eprintln!("사용법: mdemo-golden <입력> <출력>");
        std::process::exit(2)
    }
    if let Err(e) = run(Path::new(&args[1]), Path::new(&args[2])) {
        eprintln!("골든 생성 실패: {e}");
        std::process::exit(1)
    }
}
