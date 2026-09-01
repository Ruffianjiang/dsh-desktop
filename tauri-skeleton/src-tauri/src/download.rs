//! Ensures the DeepSeek Harness binary is available.
//!
//! Strategy (mirrors community desktop shells): keep the upstream repo as a Git
//! submodule pinned to a specific commit (NOT forked), then build it locally.
//! This module updates the submodule and builds it on first run. Adjust
//! `SUBMODULE_DIR` / build commands to match the pinned upstream layout.

use std::path::PathBuf;
use std::process::Command;

/// Path (relative to the crate root) of the pinned upstream submodule.
const SUBMODULE_DIR: &str = "dsh";

/// Resolve the path to the built `dsh` binary inside the submodule.
///
/// deepseek-harness builds to `dist/` via tsdown. Adapt this path if their
/// build output changes.
fn submodule_dsh_bin() -> PathBuf {
    PathBuf::from(SUBMODULE_DIR).join("dist").join("dsh")
}

/// Make sure a `dsh` binary exists. Resolution order:
///   1. `DSH_BIN` env override (handled by the supervisor) — trust the user.
///   2. Submodule already built — nothing to do.
///   3. Otherwise update the submodule and build it from source.
pub fn ensure_dsh_binary() -> Result<(), String> {
    if std::env::var("DSH_BIN").is_ok() {
        return Ok(());
    }

    let bin = submodule_dsh_bin();
    if bin.exists() {
        return Ok(());
    }

    run(Command::new("git").args([
        "submodule",
        "update",
        "--init",
        "--recursive",
        SUBMODULE_DIR,
    ]))
    .map_err(|e| format!("submodule 初始化失败: {e}"))?;

    run(Command::new("pnpm")
        .args(["install"])
        .current_dir(SUBMODULE_DIR))
    .map_err(|e| format!("pnpm install 失败: {e}"))?;

    run(Command::new("pnpm")
        .args(["build"])
        .current_dir(SUBMODULE_DIR))
    .map_err(|e| format!("pnpm build 失败: {e}"))?;

    if !bin.exists() {
        return Err(format!(
            "构建完成但未在 {:?} 找到 dsh 二进制，请检查上游构建产物路径",
            bin
        ));
    }
    Ok(())
}

fn run(mut cmd: Command) -> std::io::Result<()> {
    let status = cmd.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("命令失败: {:?}", cmd),
        ))
    }
}
