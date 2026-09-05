//! Host build of crosvm's android_codec crate (the NDK is dlopen'd, so nothing Android-specific
//! is needed at compile time); the crate's own tests run with `cargo test -p android_codec`.
pub use android_codec;
