//! Every file in src/scenes/ is a scene, compiled in by name: adding one is
//! adding a file, with no list to keep in step (src/common.wgsl says what a
//! scene file must define).
use std::{env, fs, path::Path};

fn main() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/scenes");
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
