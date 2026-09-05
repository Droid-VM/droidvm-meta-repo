//! The real files, included by path -- never a copy.
pub use android_codec;
#[path = "@W@/crosvm/devices/src/virtio/media/android_codec_backend/android.rs"]
pub mod android;
#[path = "@W@/crosvm/devices/src/virtio/media/android_codec_backend/stub.rs"]
pub mod stub;
