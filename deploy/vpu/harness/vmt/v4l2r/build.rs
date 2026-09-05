//! Puts a `bindings.rs` where `lib/src/bindings.rs`'s `include!(concat!(env!("OUT_DIR"), ...))`
//! expects one, without running bindgen: the crate's own build.rs wants bindgen 0.69, which is
//! not in this box's offline cargo cache, and soong has already generated exactly these bindings
//! for the aarch64 build (`arch64`, the layout virtio-media uses on the wire).
//!
//! Set `V4L2R_BINDINGS_RS` to override the search. If nothing is found the message says so
//! rather than the build reaching for the network: run the crosvm soong build once (it is what
//! produces the file) or point the variable at a bindings.rs from another checkout.

use std::path::PathBuf;

/// Where soong leaves the generated bindings. Both paths have held them; take whichever exists.
/// (A `\` at end of line eats the newline and the next line's indent, so these are single paths.)
const CANDIDATES: &[&str] = &[
    "@W@/crosvm_build/out/soong/.intermediates/external/rust/crates/v4l2r/android/\
libv4l2r_bindgen/android_arm64_armv8-a_source/bindings.rs",
    "@W@/crosvm_build/out/soong/.intermediates/external/rust/crates/v4l2r/lib/libv4l2r/\
android_arm64_armv8-a_rlib_rlib-std/out/bindings.rs",
];

fn main() {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    println!("cargo::rerun-if-env-changed=V4L2R_BINDINGS_RS");

    let from = match std::env::var("V4L2R_BINDINGS_RS") {
        Ok(path) => PathBuf::from(path),
        Err(_) => CANDIDATES
            .iter()
            .map(PathBuf::from)
            .find(|path| path.exists())
            .unwrap_or_else(|| {
                panic!(
                    "no generated v4l2r bindings.rs found. Looked at:\n  {}\nRun the crosvm \
                     soong build once (it generates them) or set V4L2R_BINDINGS_RS. This \
                     harness never reaches the network.",
                    CANDIDATES.join("\n  ")
                )
            }),
    };
    println!("cargo::rerun-if-changed={}", from.display());
    std::fs::copy(&from, out_dir.join("bindings.rs"))
        .unwrap_or_else(|e| panic!("failed to copy {} into OUT_DIR: {e}", from.display()));
}
