//! Every file in src/scenes/ is a scene, compiled in by name: adding one is
//! adding a file, with no list to keep in step (src/common.wgsl says what a
//! scene file must define).
use std::{env, fs, path::Path};

fn main() {
    // Read when the script RUNS, not baked in when it was compiled (`env!`):
    // a build directory shared by two checkouts reuses one compiled script,
    // and the baked path then names the other checkout's scenes.
    let directory = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("src/scenes");
    println!("cargo:rerun-if-changed={}", directory.display());
    let mut names: Vec<String> = fs::read_dir(&directory)
        .expect("src/scenes")
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            (path.extension()? == "wgsl").then(|| path.file_stem()?.to_str().map(String::from))?
        })
        .collect();
    names.sort();
    let entries: String = names
        .iter()
        .map(|name| format!("    ({name:?}, include_str!({:?})),\n", directory.join(format!("{name}.wgsl")).display().to_string()))
        .collect();
    let destination = Path::new(&env::var("OUT_DIR").unwrap()).join("scenes.rs");
    fs::write(destination, format!("&[\n{entries}]\n")).expect("write scenes.rs");
}
