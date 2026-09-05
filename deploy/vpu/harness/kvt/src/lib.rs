//! The `--virtio-media` command-line surface, lifted out of the real sources by `build.rs`:
//! `MediaDeviceKind` and its support table (which kinds exist and where), `MediaDeviceConfig`,
//! and the `#[cfg(test)]` modules that live beside each of them in crosvm.
include!(concat!(env!("OUT_DIR"), "/extracted.rs"));
