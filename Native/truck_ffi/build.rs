// SPDX-License-Identifier: MIT

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let crate_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("missing CARGO_MANIFEST_DIR"));
    let include_dir = crate_dir.join("include");
    let header_path = include_dir.join("truck_ffi.h");
    let config_path = crate_dir.join("cbindgen.toml");

    std::fs::create_dir_all(&include_dir).expect("failed to create include directory");

    let status = Command::new("cbindgen")
        .arg("--config")
        .arg(&config_path)
        .arg("--crate")
        .arg("truck_ffi")
        .arg("--output")
        .arg(&header_path)
        .current_dir(&crate_dir)
        .status();

    match status {
        Ok(code) if code.success() => {}
        Ok(code) => {
            panic!(
                "cbindgen exited with status {}. Install cbindgen and retry cargo build.",
                code
            )
        }
        Err(error) => {
            panic!(
                "failed to invoke cbindgen ({error}). Install cbindgen and retry cargo build."
            )
        }
    }
}
