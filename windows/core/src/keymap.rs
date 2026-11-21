//! Key positions shared by the two platforms.
//!
//! The protocol carries macOS virtual key codes, which name positions on an ANSI keyboard rather than
//! characters. Windows names positions by set-1 scan codes, so keys map position to position and each
//! system's own keyboard layout decides the character. Only modifier keys are a matter of preference.

/// A key as Windows identifies it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PcKey {
    /// A set-1 scan code; `extended` is the E0 prefix that tells the right-hand and navigation keys apart.
    Scan { code: u16, extended: bool },
    /// A virtual key code, for the few keys whose scan sequence Windows does not accept as input.
    Virtual(u16),
}

const fn scan(code: u16) -> PcKey {
    PcKey::Scan { code, extended: false }
}

const fn extended(code: u16) -> PcKey {
    PcKey::Scan { code, extended: true }
}

pub mod pc {
    use super::{PcKey, extended, scan};
    pub const LEFT_SHIFT: PcKey = scan(0x2A);
    pub const RIGHT_SHIFT: PcKey = scan(0x36);
    pub const LEFT_CONTROL: PcKey = scan(0x1D);
    pub const RIGHT_CONTROL: PcKey = extended(0x1D);
    pub const LEFT_ALT: PcKey = scan(0x38);
    pub const RIGHT_ALT: PcKey = extended(0x38);
    pub const LEFT_WINDOWS: PcKey = extended(0x5B);
    pub const RIGHT_WINDOWS: PcKey = extended(0x5C);
    pub const CAPS_LOCK: PcKey = scan(0x3A);
    pub const VK_PAUSE: u16 = 0x13;
    pub const VK_SNAPSHOT: u16 = 0x2C;
}

pub mod mac {
    pub const RIGHT_COMMAND: u16 = 54;
    pub const COMMAND: u16 = 55;
    pub const SHIFT: u16 = 56;
    pub const CAPS_LOCK: u16 = 57;
    pub const OPTION: u16 = 58;
    pub const CONTROL: u16 = 59;
    pub const RIGHT_SHIFT: u16 = 60;
    pub const RIGHT_OPTION: u16 = 61;
    pub const RIGHT_CONTROL: u16 = 62;

    /// `NSEvent.ModifierFlags` bits.
    pub const FLAG_CAPS_LOCK: u64 = 1 << 16;
    pub const FLAG_SHIFT: u64 = 1 << 17;
    pub const FLAG_CONTROL: u64 = 1 << 18;
    pub const FLAG_OPTION: u64 = 1 << 19;
    pub const FLAG_COMMAND: u64 = 1 << 20;
    pub const FLAG_NUMERIC_PAD: u64 = 1 << 21;
    pub const FLAG_FUNCTION: u64 = 1 << 23;
    /// The low bits say which of the left and right keys is down.
    pub const DEVICE_FLAGS: u64 = 0x207F;

    /// The device bit and the device-independent bit of a modifier key.
    pub fn modifier_flags(key_code: u16) -> Option<(u64, u64)> {
        Some(match key_code {
            CONTROL => (0x01, FLAG_CONTROL),
            SHIFT => (0x02, FLAG_SHIFT),
            RIGHT_SHIFT => (0x04, FLAG_SHIFT),
            COMMAND => (0x08, FLAG_COMMAND),
            RIGHT_COMMAND => (0x10, FLAG_COMMAND),
            OPTION => (0x20, FLAG_OPTION),
            RIGHT_OPTION => (0x40, FLAG_OPTION),
            RIGHT_CONTROL => (0x2000, FLAG_CONTROL),
            _ => return None,
        })
    }

    /// The flags AppKit adds to the events of keys outside the main block.
    pub fn key_flags(key_code: u16) -> u64 {
        match key_code {
            123..=126 => FLAG_NUMERIC_PAD | FLAG_FUNCTION,
            65 | 67 | 69 | 71 | 75 | 76 | 78 | 81..=89 | 91 | 92 => FLAG_NUMERIC_PAD,
            96..=101 | 103 | 105..=107 | 109 | 111 | 113..=122 | 64 | 79 | 80 | 90 => FLAG_FUNCTION,
            _ => 0,
        }
    }
}

/// macOS virtual key code and the PC key at the same position, modifiers excluded.
const KEYS: &[(u16, PcKey)] = &[
    (0x00, scan(0x1E)),     // A
    (0x01, scan(0x1F)),     // S
    (0x02, scan(0x20)),     // D
    (0x03, scan(0x21)),     // F
    (0x04, scan(0x23)),     // H
    (0x05, scan(0x22)),     // G
    (0x06, scan(0x2C)),     // Z
    (0x07, scan(0x2D)),     // X
    (0x08, scan(0x2E)),     // C
    (0x09, scan(0x2F)),     // V
    (0x0A, scan(0x56)),     // ISO section, the extra key of ISO keyboards
    (0x0B, scan(0x30)),     // B
    (0x0C, scan(0x10)),     // Q
    (0x0D, scan(0x11)),     // W
    (0x0E, scan(0x12)),     // E
    (0x0F, scan(0x13)),     // R
    (0x10, scan(0x15)),     // Y
    (0x11, scan(0x14)),     // T
    (0x12, scan(0x02)),     // 1
    (0x13, scan(0x03)),     // 2
    (0x14, scan(0x04)),     // 3
    (0x15, scan(0x05)),     // 4
    (0x16, scan(0x07)),     // 6
    (0x17, scan(0x06)),     // 5
    (0x18, scan(0x0D)),     // =
    (0x19, scan(0x0A)),     // 9
    (0x1A, scan(0x08)),     // 7
    (0x1B, scan(0x0C)),     // -
    (0x1C, scan(0x09)),     // 8
    (0x1D, scan(0x0B)),     // 0
    (0x1E, scan(0x1B)),     // ]
    (0x1F, scan(0x18)),     // O
    (0x20, scan(0x16)),     // U
    (0x21, scan(0x1A)),     // [
    (0x22, scan(0x17)),     // I
    (0x23, scan(0x19)),     // P
    (0x24, scan(0x1C)),     // Return
    (0x25, scan(0x26)),     // L
    (0x26, scan(0x24)),     // J
    (0x27, scan(0x28)),     // '
    (0x28, scan(0x25)),     // K
    (0x29, scan(0x27)),     // ;
    (0x2A, scan(0x2B)),     // \
    (0x2B, scan(0x33)),     // ,
    (0x2C, scan(0x35)),     // /
    (0x2D, scan(0x31)),     // N
    (0x2E, scan(0x32)),     // M
    (0x2F, scan(0x34)),     // .
    (0x30, scan(0x0F)),     // Tab
    (0x31, scan(0x39)),     // Space
    (0x32, scan(0x29)),     // `
    (0x33, scan(0x0E)),     // Delete, Backspace on a PC
    (0x35, scan(0x01)),     // Escape
    (0x40, scan(0x68)),     // F17
    (0x41, scan(0x53)),     // Keypad .
    (0x43, scan(0x37)),     // Keypad *
    (0x45, scan(0x4E)),     // Keypad +
    (0x47, extended(0x45)), // Keypad Clear, Num Lock on a PC
    (0x48, extended(0x30)), // Volume up
    (0x49, extended(0x2E)), // Volume down
    (0x4A, extended(0x20)), // Mute
    (0x4B, extended(0x35)), // Keypad /
    (0x4C, extended(0x1C)), // Keypad Enter
    (0x4E, scan(0x4A)),     // Keypad -
    (0x4F, scan(0x69)),     // F18
    (0x50, scan(0x6A)),     // F19
    (0x52, scan(0x52)),     // Keypad 0
    (0x53, scan(0x4F)),     // Keypad 1
    (0x54, scan(0x50)),     // Keypad 2
    (0x55, scan(0x51)),     // Keypad 3
    (0x56, scan(0x4B)),     // Keypad 4
    (0x57, scan(0x4C)),     // Keypad 5
    (0x58, scan(0x4D)),     // Keypad 6
    (0x59, scan(0x47)),     // Keypad 7
    (0x5A, scan(0x6B)),     // F20
    (0x5B, scan(0x48)),     // Keypad 8
    (0x5C, scan(0x49)),     // Keypad 9
    (0x5D, scan(0x7D)),     // JIS yen
    (0x5E, scan(0x73)),     // JIS underscore
    (0x5F, scan(0x7E)),     // JIS keypad comma
    (0x60, scan(0x3F)),     // F5
    (0x61, scan(0x40)),     // F6
    (0x62, scan(0x41)),     // F7
    (0x63, scan(0x3D)),     // F3
    (0x64, scan(0x42)),     // F8
    (0x65, scan(0x43)),     // F9
    (0x66, scan(0x7B)),     // JIS eisu
    (0x67, scan(0x57)),     // F11
    (0x68, scan(0x79)),     // JIS kana
    // Apple keyboards carry F13 to F15 where a PC has Print Screen, Scroll Lock and Pause.
    (0x69, PcKey::Virtual(pc::VK_SNAPSHOT)),
    (0x6A, scan(0x67)),     // F16
    (0x6B, scan(0x46)),     // F14, Scroll Lock
    (0x6D, scan(0x44)),     // F10
    (0x6E, extended(0x5D)), // Contextual menu
    (0x6F, scan(0x58)),     // F12
    (0x71, PcKey::Virtual(pc::VK_PAUSE)),
    (0x72, extended(0x52)), // Help, Insert on a PC
    (0x73, extended(0x47)), // Home
    (0x74, extended(0x49)), // Page Up
    (0x75, extended(0x53)), // Forward Delete
    (0x76, scan(0x3E)),     // F4
    (0x77, extended(0x4F)), // End
    (0x78, scan(0x3C)),     // F2
    (0x79, extended(0x51)), // Page Down
    (0x7A, scan(0x3B)),     // F1
    (0x7B, extended(0x4B)), // Left
    (0x7C, extended(0x4D)), // Right
    (0x7D, extended(0x50)), // Down
    (0x7E, extended(0x48)), // Up
];

/// How a Windows host reads the modifier keys of a Mac keyboard.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MacModifierMapping {
    /// Left Command and Control both act as Ctrl, so Mac shortcuts such as Command-C keep working;
    /// right Command is the Windows key.
    #[default]
    CommandAsControl,
    /// Control is Ctrl, Option is Alt and Command is the Windows key.
    Standard,
}

/// How a Windows viewer presents the modifier keys of a PC keyboard to a Mac.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PcModifierMapping {
    /// Apple's mapping for PC keyboards: Ctrl is Control, Alt is Option and the Windows key is Command.
    #[default]
    Standard,
    /// Left Ctrl acts as Command, so Windows shortcuts such as Ctrl+C keep working; right Ctrl stays Control.
    ControlAsCommand,
}

/// The PC key at the position of a macOS key, modifiers excluded.
pub fn pc_key(mac_key: u16) -> Option<PcKey> {
    KEYS.iter().find(|(code, _)| *code == mac_key).map(|(_, key)| *key)
}

/// The macOS key at the position of a PC key, modifiers excluded.
pub fn mac_key(key: PcKey) -> Option<u16> {
    // The first entry wins where two macOS keys share a PC key.
    KEYS.iter().find(|(_, candidate)| *candidate == key).map(|(code, _)| *code)
}

pub fn pc_modifier(mac_key: u16, mapping: MacModifierMapping) -> Option<PcKey> {
    use MacModifierMapping::{CommandAsControl, Standard};
    Some(match (mac_key, mapping) {
        (mac::SHIFT, _) => pc::LEFT_SHIFT,
        (mac::RIGHT_SHIFT, _) => pc::RIGHT_SHIFT,
        (mac::OPTION, _) => pc::LEFT_ALT,
        (mac::RIGHT_OPTION, _) => pc::RIGHT_ALT,
        (mac::CONTROL, _) => pc::LEFT_CONTROL,
        (mac::RIGHT_CONTROL, _) => pc::RIGHT_CONTROL,
        (mac::COMMAND, CommandAsControl) => pc::LEFT_CONTROL,
        (mac::COMMAND, Standard) => pc::LEFT_WINDOWS,
        (mac::RIGHT_COMMAND, _) => pc::RIGHT_WINDOWS,
        _ => return None,
    })
}

pub fn mac_modifier(key: PcKey, mapping: PcModifierMapping) -> Option<u16> {
    use PcModifierMapping::{ControlAsCommand, Standard};
    Some(match (key, mapping) {
        (pc::LEFT_SHIFT, _) => mac::SHIFT,
        (pc::RIGHT_SHIFT, _) => mac::RIGHT_SHIFT,
        (pc::LEFT_ALT, _) => mac::OPTION,
        (pc::RIGHT_ALT, _) => mac::RIGHT_OPTION,
        (pc::LEFT_CONTROL, Standard) => mac::CONTROL,
        (pc::LEFT_CONTROL, ControlAsCommand) => mac::COMMAND,
        (pc::RIGHT_CONTROL, _) => mac::RIGHT_CONTROL,
        (pc::LEFT_WINDOWS, _) => mac::COMMAND,
        (pc::RIGHT_WINDOWS, _) => mac::RIGHT_COMMAND,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn positions_map_one_to_one_in_both_directions() {
        let codes: HashSet<u16> = KEYS.iter().map(|(code, _)| *code).collect();
        let keys: HashSet<PcKey> = KEYS.iter().map(|(_, key)| *key).collect();
        assert_eq!((codes.len(), keys.len()), (KEYS.len(), KEYS.len()));
        for (code, key) in KEYS {
            assert_eq!((pc_key(*code), mac_key(*key)), (Some(*key), Some(*code)));
            assert!(*code <= 127 && mac::modifier_flags(*code).is_none());
        }
    }

    #[test]
    fn letters_digits_and_navigation_keep_their_positions() {
        assert_eq!(pc_key(0x08), Some(scan(0x2E))); // C
        assert_eq!(pc_key(0x12), Some(scan(0x02))); // 1
        assert_eq!(pc_key(0x33), Some(scan(0x0E))); // Backspace
        assert_eq!(pc_key(0x75), Some(extended(0x53))); // Forward Delete
        assert_eq!(pc_key(0x7E), Some(extended(0x48))); // Up
        assert_eq!(mac_key(extended(0x1C)), Some(0x4C)); // Keypad Enter
        assert_eq!(mac_key(scan(0x1C)), Some(0x24)); // Return
        assert_eq!(pc_key(mac::COMMAND), None);
    }

    #[test]
    fn modifier_preferences_differ_only_for_command_and_control() {
        assert_eq!(pc_modifier(mac::COMMAND, MacModifierMapping::CommandAsControl), Some(pc::LEFT_CONTROL));
        assert_eq!(pc_modifier(mac::COMMAND, MacModifierMapping::Standard), Some(pc::LEFT_WINDOWS));
        assert_eq!(pc_modifier(mac::RIGHT_COMMAND, MacModifierMapping::CommandAsControl), Some(pc::RIGHT_WINDOWS));
        assert_eq!(pc_modifier(mac::CONTROL, MacModifierMapping::CommandAsControl), Some(pc::LEFT_CONTROL));
        assert_eq!(pc_modifier(mac::OPTION, MacModifierMapping::Standard), Some(pc::LEFT_ALT));
        assert_eq!(mac_modifier(pc::LEFT_CONTROL, PcModifierMapping::Standard), Some(mac::CONTROL));
        assert_eq!(mac_modifier(pc::LEFT_CONTROL, PcModifierMapping::ControlAsCommand), Some(mac::COMMAND));
        assert_eq!(mac_modifier(pc::RIGHT_CONTROL, PcModifierMapping::ControlAsCommand), Some(mac::RIGHT_CONTROL));
        assert_eq!(mac_modifier(pc::LEFT_WINDOWS, PcModifierMapping::Standard), Some(mac::COMMAND));
        assert_eq!(mac_modifier(scan(0x1E), PcModifierMapping::Standard), None);
    }
}
