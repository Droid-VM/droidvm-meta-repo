//! The real files, included by path -- never a copy.
pub use android_camera;
#[path = "@W@/crosvm/devices/src/virtio/media/android_camera_backend/android.rs"]
pub mod android;
#[path = "@W@/crosvm/devices/src/virtio/media/android_camera_backend/stub.rs"]
pub mod stub;
/// The `camera_probe` binary's source, as a module: its `main` is dead code here, but the file
/// is type-checked, which nothing else on this host does (a `[[bin]]` of a dependency crate is
/// not built by its dependents).
#[path = "@W@/crosvm/android_camera/src/probe.rs"]
#[allow(dead_code)]
pub mod probe;
