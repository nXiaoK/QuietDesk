//! QuietDesk wire protocol, pairing transport and session logic.
//!
//! This crate speaks the baseline protocol of the macOS application (`Sources/QuietDeskCore`):
//! TLS 1.2 with a pre-shared pairing key, length-prefixed messages, JSON control messages and
//! H.264 access units acknowledged by sequence number. It has no platform dependencies, so the
//! same code runs in the Windows application and in the interoperability checks on macOS.

pub mod error;
pub mod host;
pub mod input;
pub mod keymap;
pub mod media;
pub mod messages;
pub mod pairing;
pub mod peer;
pub mod pixel;
pub mod tls;
pub mod video;
pub mod viewer;
pub mod wire;

pub use error::DeskError;
pub use pairing::PairingKey;
