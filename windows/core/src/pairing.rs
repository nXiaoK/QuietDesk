use crate::error::{DeskError, Result};
use std::fmt;

/// The 256-bit pairing secret both sides use as the TLS pre-shared key.
#[derive(Clone, PartialEq, Eq)]
pub struct PairingKey([u8; 32]);

impl PairingKey {
    pub const BYTES: usize = 32;

    /// Accepts 64 hexadecimal digits; whitespace and hyphens between them are ignored.
    pub fn parse(code: &str) -> Result<Self> {
        let digits: Vec<u8> = code.bytes().filter(|byte| !byte.is_ascii_whitespace() && *byte != b'-').collect();
        if digits.len() != Self::BYTES * 2 || !digits.iter().all(u8::is_ascii_hexdigit) {
            return Err(DeskError::invalid("配对码应为完整的 64 位十六进制字符，可保留横线"));
        }
        let mut key = [0u8; Self::BYTES];
        for (byte, pair) in key.iter_mut().zip(digits.as_chunks::<2>().0) {
            let text = std::str::from_utf8(pair).map_err(|_| DeskError::invalid("配对码格式错误"))?;
            *byte = u8::from_str_radix(text, 16).map_err(|_| DeskError::invalid("配对码格式错误"))?;
        }
        Ok(Self(key))
    }

    pub fn generate() -> Result<Self> {
        let mut key = [0u8; Self::BYTES];
        openssl::rand::rand_bytes(&mut key).map_err(|error| DeskError::platform(format!("无法生成配对码：{error}")))?;
        Ok(Self(key))
    }

    pub fn from_bytes(bytes: [u8; Self::BYTES]) -> Self {
        Self(bytes)
    }

    pub fn bytes(&self) -> &[u8; Self::BYTES] {
        &self.0
    }

    /// Upper-case hexadecimal in groups of eight, as the macOS application shows it.
    pub fn code(&self) -> String {
        let hex: String = self.0.iter().map(|byte| format!("{byte:02X}")).collect();
        hex.as_bytes().chunks(8).map(|group| std::str::from_utf8(group).unwrap_or_default()).collect::<Vec<_>>().join("-")
    }
}

impl fmt::Debug for PairingKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PairingKey(..)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_round_trips_with_and_without_separators() {
        let key = PairingKey::from_bytes(std::array::from_fn(|index| index as u8 * 7));
        let code = key.code();
        assert_eq!(code.len(), 64 + 7);
        assert_eq!(code.split('-').count(), 8);
        assert_eq!(PairingKey::parse(&code).unwrap(), key);
        assert_eq!(PairingKey::parse(&code.replace('-', " ").to_lowercase()).unwrap(), key);
    }

    #[test]
    fn rejects_short_or_non_hexadecimal_codes() {
        assert!(PairingKey::parse("ABCD").is_err());
        assert!(PairingKey::parse(&"G".repeat(64)).is_err());
        assert!(PairingKey::parse(&"A".repeat(66)).is_err());
    }

    #[test]
    fn generated_keys_differ() {
        assert_ne!(PairingKey::generate().unwrap(), PairingKey::generate().unwrap());
    }
}
