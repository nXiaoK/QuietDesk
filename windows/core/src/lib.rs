//! QuietDesk wire protocol, pairing transport and session logic.
//!
//! This crate speaks the protocol of the macOS application (`Sources/QuietDeskCore`) for the capabilities
//! the Windows client announces: TLS 1.2 with a pre-shared pairing key, length-prefixed messages, the
//! media session over TCP and over DTLS datagrams with repair and forward error correction, the
//! independent cursor, clipboard and file transfer, remote audio and display switching. It has no
//! Windows dependencies, so the same code runs in the Windows application and in the
//! interoperability checks on macOS.

pub mod audio;
pub mod audio_session;
mod auxiliary;
pub mod clipboard;
pub mod clipboard_session;
pub mod cursor;
pub mod cursor_pixels;
mod datagram_frames;
mod datagram_path;
pub mod datagram_transport;
pub mod display;
pub mod error;
pub mod host;
pub mod input;
pub mod keymap;
pub mod media;
pub mod messages;
pub mod pairing;
pub mod peer;
pub mod pixel;
pub mod reliability;
pub mod tls;
pub mod video;
mod video_pacing;
pub mod viewer;
pub mod wire;

pub use error::DeskError;
pub use pairing::PairingKey;
