//! Translation between `RemoteInput` and what each Windows role does with it.
//!
//! A Windows host turns the events of any viewer into key, button and wheel operations for `SendInput`.
//! A Windows viewer turns its window's key and mouse messages into the events a host expects, which for a
//! Mac host means macOS key codes and `NSEvent` modifier flags.

use crate::keymap::{self, MacModifierMapping, PcKey, PcModifierMapping, mac, pc};
use crate::messages::{InputKind, RemoteInput};
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    X1,
    X2,
}

impl MouseButton {
    /// Button numbers as `CGMouseButton` counts them; the two side buttons follow the middle one.
    fn from_number(number: i64) -> Option<Self> {
        [Self::Left, Self::Right, Self::Middle, Self::X1, Self::X2].get(usize::try_from(number).ok()?).copied()
    }
}

/// One operation for the host to inject, in order.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum InjectOp {
    Key {
        key: PcKey,
        down: bool,
    },
    /// Pointer position as fractions of the shared display.
    Move {
        x: f64,
        y: f64,
    },
    Button {
        button: MouseButton,
        down: bool,
    },
    /// Wheel movement in units of 1/120 notch; positive is away from the user and to the right.
    Wheel {
        vertical: i32,
        horizontal: i32,
    },
    /// Make the Caps Lock state equal this.
    CapsLock(bool),
}

/// Wheel units for one line of a mouse wheel: Windows scrolls three lines per 120-unit notch by default.
const WHEEL_UNITS_PER_LINE: f64 = 40.0;
/// Wheel units for one pixel of a trackpad gesture, taking a notch as roughly 80 pixels of content.
const WHEEL_UNITS_PER_PIXEL: f64 = 1.5;

/// State a Windows host keeps for one viewer.
pub struct HostInputTranslator {
    mapping: MacModifierMapping,
    /// macOS modifier keys the viewer holds.
    modifiers: BTreeSet<u16>,
    /// PC modifier keys injected as down. Two macOS keys may hold the same one.
    pc_modifiers: BTreeSet<PcKey>,
    keys: BTreeSet<PcKey>,
    buttons: BTreeSet<MouseButton>,
    wheel_remainder: (f64, f64),
}

impl HostInputTranslator {
    pub fn new(mapping: MacModifierMapping) -> Self {
        Self {
            mapping,
            modifiers: BTreeSet::new(),
            pc_modifiers: BTreeSet::new(),
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            wheel_remainder: (0.0, 0.0),
        }
    }

    /// The operations for one validated event. Kinds this host did not advertise produce nothing.
    pub fn translate(&mut self, input: &RemoteInput) -> Vec<InjectOp> {
        let mut ops = Vec::new();
        match input.kind {
            InputKind::Flags if input.key_code == mac::CAPS_LOCK => {
                ops.push(InjectOp::CapsLock(input.flags & mac::FLAG_CAPS_LOCK != 0));
            }
            InputKind::Flags => {
                let Some((device, general)) = mac::modifier_flags(input.key_code) else { return ops };
                // Events that carry device bits say which of the two keys changed; older ones only say the kind.
                let down = if input.flags & mac::DEVICE_FLAGS != 0 { input.flags & device != 0 } else { input.flags & general != 0 };
                if down {
                    self.modifiers.insert(input.key_code);
                } else {
                    self.modifiers.remove(&input.key_code);
                }
                self.apply_modifiers(&mut ops);
            }
            InputKind::KeyDown | InputKind::KeyUp => {
                let down = input.kind == InputKind::KeyDown;
                let Some(key) = keymap::pc_key(input.key_code) else { return ops };
                if down {
                    // The event's own flags decide the modifiers of a keystroke, as they do on a Mac host;
                    // a modifier change this host never saw must not turn the key into another shortcut.
                    self.adopt_flags(input.flags);
                    self.apply_modifiers(&mut ops);
                    ops.push(InjectOp::CapsLock(input.flags & mac::FLAG_CAPS_LOCK != 0));
                    self.keys.insert(key);
                } else if !self.keys.remove(&key) {
                    return ops;
                }
                ops.push(InjectOp::Key { key, down });
            }
            InputKind::Move | InputKind::Drag => ops.push(InjectOp::Move { x: input.x, y: input.y }),
            InputKind::Down | InputKind::Up => {
                let down = input.kind == InputKind::Down;
                ops.push(InjectOp::Move { x: input.x, y: input.y });
                let Some(button) = MouseButton::from_number(input.button) else { return ops };
                if if down { self.buttons.insert(button) } else { self.buttons.remove(&button) } {
                    ops.push(InjectOp::Button { button, down });
                }
            }
            InputKind::Scroll => {
                // The wheel goes to the window under the pointer.
                ops.push(InjectOp::Move { x: input.x, y: input.y });
                let (x, y) = match (input.line_delta_x, input.line_delta_y) {
                    (Some(x), Some(y)) => (x * WHEEL_UNITS_PER_LINE, y * WHEEL_UNITS_PER_LINE),
                    _ => (input.delta_x * WHEEL_UNITS_PER_PIXEL, input.delta_y * WHEEL_UNITS_PER_PIXEL),
                };
                // macOS counts a horizontal delta as positive towards the left, Windows towards the right.
                let (horizontal, vertical) = (self.wheel_remainder.0 - x, self.wheel_remainder.1 + y);
                self.wheel_remainder = (horizontal.fract(), vertical.fract());
                let (horizontal, vertical) = (horizontal.trunc() as i32, vertical.trunc() as i32);
                if horizontal != 0 || vertical != 0 {
                    ops.push(InjectOp::Wheel { vertical, horizontal });
                }
            }
            InputKind::Magnify | InputKind::Rotate | InputKind::SmartMagnify | InputKind::SwitchInputSource | InputKind::ToggleCapsLock => {}
        }
        ops
    }

    /// Releases everything this viewer holds, for a lost focus, a pause or the end of the session.
    pub fn release_all(&mut self) -> Vec<InjectOp> {
        let mut ops: Vec<InjectOp> = std::mem::take(&mut self.keys).into_iter().map(|key| InjectOp::Key { key, down: false }).collect();
        self.modifiers.clear();
        self.apply_modifiers(&mut ops);
        ops.extend(std::mem::take(&mut self.buttons).into_iter().map(|button| InjectOp::Button { button, down: false }));
        self.wheel_remainder = (0.0, 0.0);
        ops
    }

    fn adopt_flags(&mut self, flags: u64) {
        for (general, left, right) in [
            (mac::FLAG_COMMAND, mac::COMMAND, mac::RIGHT_COMMAND),
            (mac::FLAG_SHIFT, mac::SHIFT, mac::RIGHT_SHIFT),
            (mac::FLAG_OPTION, mac::OPTION, mac::RIGHT_OPTION),
            (mac::FLAG_CONTROL, mac::CONTROL, mac::RIGHT_CONTROL),
        ] {
            let held = self.modifiers.contains(&left) || self.modifiers.contains(&right);
            if flags & general != 0 && !held {
                self.modifiers.insert(left);
            } else if flags & general == 0 && held {
                self.modifiers.remove(&left);
                self.modifiers.remove(&right);
            }
        }
    }

    fn apply_modifiers(&mut self, ops: &mut Vec<InjectOp>) {
        let wanted: BTreeSet<PcKey> = self.modifiers.iter().filter_map(|code| keymap::pc_modifier(*code, self.mapping)).collect();
        ops.extend(self.pc_modifiers.difference(&wanted).map(|key| InjectOp::Key { key: *key, down: false }));
        ops.extend(wanted.difference(&self.pc_modifiers).map(|key| InjectOp::Key { key: *key, down: true }));
        self.pc_modifiers = wanted;
    }
}

/// A key message of the viewer's window.
#[derive(Clone, Copy, Debug)]
pub struct PcKeyEvent {
    pub scan_code: u16,
    pub extended: bool,
    pub virtual_key: u16,
    pub down: bool,
    pub repeat: bool,
}

/// Lines a 120-unit wheel notch scrolls, the Windows default.
const LINES_PER_NOTCH: f64 = 3.0;
/// Pixels the macOS viewer reports per wheel line.
const PIXELS_PER_LINE: f64 = 12.0;

/// State a Windows viewer keeps for one session.
pub struct ViewerInputTranslator {
    mapping: PcModifierMapping,
    /// Held PC modifier keys and the macOS key each one stands for.
    modifiers: BTreeMap<PcKey, u16>,
    caps_lock: bool,
    /// Held keys and the macOS key code sent for each, so the release names the same key.
    keys: BTreeMap<PcKey, u16>,
    buttons: BTreeSet<i64>,
    click: Option<Click>,
    double_click: DoubleClick,
}

/// When a second press continues a click sequence, as the system's double-click settings define it.
#[derive(Clone, Copy, Debug)]
pub struct DoubleClick {
    pub interval: Duration,
    pub distance: i32,
}

#[derive(Clone, Copy)]
struct Click {
    button: i64,
    at: Duration,
    pixel: (i32, i32),
    count: i64,
}

impl ViewerInputTranslator {
    pub fn new(mapping: PcModifierMapping, double_click: DoubleClick) -> Self {
        Self { mapping, modifiers: BTreeMap::new(), caps_lock: false, keys: BTreeMap::new(), buttons: BTreeSet::new(), click: None, double_click }
    }

    fn flags(&self) -> u64 {
        let held = self.modifiers.values().filter_map(|code| mac::modifier_flags(*code)).fold(0, |flags, (device, general)| flags | device | general);
        held | if self.caps_lock { mac::FLAG_CAPS_LOCK } else { 0 }
    }

    fn pointer(&self, kind: InputKind, x: f64, y: f64) -> RemoteInput {
        let mut input = RemoteInput::new(kind);
        input.x = x.clamp(0.0, 1.0);
        input.y = y.clamp(0.0, 1.0);
        input.flags = self.flags();
        input
    }

    /// `caps_lock` is the toggle state after this event, as the system reports it.
    pub fn key(&mut self, event: PcKeyEvent, caps_lock: bool) -> Option<RemoteInput> {
        let key = match event.virtual_key {
            pc::VK_PAUSE | pc::VK_SNAPSHOT => PcKey::Virtual(event.virtual_key),
            _ => PcKey::Scan { code: event.scan_code, extended: event.extended },
        };
        if key == pc::CAPS_LOCK {
            // A host follows the lock state, so only the press that changed it is an event.
            if !event.down || event.repeat || caps_lock == self.caps_lock {
                return None;
            }
            self.caps_lock = caps_lock;
            return Some(self.modifier_event(mac::CAPS_LOCK));
        }
        if let Some(code) = keymap::mac_modifier(key, self.mapping) {
            let changed = if event.down { self.modifiers.insert(key, code).is_none() } else { self.modifiers.remove(&key).is_some() };
            return changed.then(|| self.modifier_event(code));
        }
        let code = if event.down { keymap::mac_key(key)? } else { self.keys.remove(&key)? };
        if event.down {
            self.keys.insert(key, code);
        }
        self.caps_lock = caps_lock;
        let mut input = RemoteInput::new(if event.down { InputKind::KeyDown } else { InputKind::KeyUp });
        input.key_code = code;
        input.flags = self.flags() | mac::key_flags(code);
        input.is_repeat = event.down && event.repeat;
        Some(input)
    }

    fn modifier_event(&self, code: u16) -> RemoteInput {
        let mut input = RemoteInput::new(InputKind::Flags);
        input.key_code = code;
        input.flags = self.flags();
        input
    }

    pub fn pointer_move(&self, x: f64, y: f64) -> RemoteInput {
        let Some(button) = self.buttons.first() else { return self.pointer(InputKind::Move, x, y) };
        let mut input = self.pointer(InputKind::Drag, x, y);
        input.button = *button;
        input.clicks = self.click.filter(|click| click.button == *button).map_or(1, |click| click.count);
        input
    }

    /// Buttons whose press was forwarded and still needs a matching release.
    pub fn pressed_buttons(&self) -> &BTreeSet<i64> {
        &self.buttons
    }

    /// `at` is a monotonic time and `pixel` the position in window pixels, both only compared with earlier presses.
    pub fn button(&mut self, button: i64, down: bool, x: f64, y: f64, at: Duration, pixel: (i32, i32)) -> RemoteInput {
        if down {
            let continues = self.click.filter(|click| {
                click.button == button
                    && at.saturating_sub(click.at) <= self.double_click.interval
                    && (click.pixel.0 - pixel.0).abs() <= self.double_click.distance
                    && (click.pixel.1 - pixel.1).abs() <= self.double_click.distance
            });
            // The protocol counts up to a triple click.
            let count = continues.map_or(1, |click| click.count % 3 + 1);
            self.click = Some(Click { button, at, pixel, count });
            self.buttons.insert(button);
        } else {
            self.buttons.remove(&button);
        }
        let mut input = self.pointer(if down { InputKind::Down } else { InputKind::Up }, x, y);
        input.button = button;
        input.clicks = self.click.filter(|click| click.button == button).map_or(1, |click| click.count);
        input
    }

    /// Wheel movement in notches; positive is away from the user and to the right.
    pub fn wheel(&self, vertical: f64, horizontal: f64, x: f64, y: f64) -> RemoteInput {
        let mut input = self.pointer(InputKind::Scroll, x, y);
        let limit = RemoteInput::MAXIMUM_LINE_DELTA;
        let (lines_x, lines_y) = ((-horizontal * LINES_PER_NOTCH).clamp(-limit, limit), (vertical * LINES_PER_NOTCH).clamp(-limit, limit));
        input.line_delta_x = Some(lines_x);
        input.line_delta_y = Some(lines_y);
        input.delta_x = lines_x * PIXELS_PER_LINE;
        input.delta_y = lines_y * PIXELS_PER_LINE;
        input
    }

    /// Forgets held keys and buttons after the host was told to release them.
    pub fn release_all(&mut self) {
        self.modifiers.clear();
        self.keys.clear();
        self.buttons.clear();
        self.click = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const C: u16 = 0x08;
    const PC_C: PcKey = PcKey::Scan { code: 0x2E, extended: false };

    fn flags_event(key_code: u16, flags: u64) -> RemoteInput {
        let mut input = RemoteInput::new(InputKind::Flags);
        input.key_code = key_code;
        input.flags = flags;
        input
    }

    fn key_event(kind: InputKind, key_code: u16, flags: u64) -> RemoteInput {
        let mut input = RemoteInput::new(kind);
        input.key_code = key_code;
        input.flags = flags;
        input
    }

    fn key(key: PcKey, down: bool) -> InjectOp {
        InjectOp::Key { key, down }
    }

    #[test]
    fn command_c_from_a_mac_becomes_control_c_or_windows_c() {
        let command = mac::FLAG_COMMAND | 0x08;
        for (mapping, modifier) in [(MacModifierMapping::CommandAsControl, pc::LEFT_CONTROL), (MacModifierMapping::Standard, pc::LEFT_WINDOWS)] {
            let mut host = HostInputTranslator::new(mapping);
            assert_eq!(host.translate(&flags_event(mac::COMMAND, command)), [key(modifier, true)]);
            assert_eq!(host.translate(&key_event(InputKind::KeyDown, C, command)), [InjectOp::CapsLock(false), key(PC_C, true)]);
            assert_eq!(host.translate(&key_event(InputKind::KeyUp, C, command)), [key(PC_C, false)]);
            assert_eq!(host.translate(&flags_event(mac::COMMAND, 0)), [key(modifier, false)]);
        }
    }

    #[test]
    fn two_macos_modifiers_sharing_one_pc_key_release_it_only_when_both_are_up() {
        let mut host = HostInputTranslator::new(MacModifierMapping::CommandAsControl);
        assert_eq!(host.translate(&flags_event(mac::COMMAND, mac::FLAG_COMMAND | 0x08)), [key(pc::LEFT_CONTROL, true)]);
        assert_eq!(host.translate(&flags_event(mac::CONTROL, mac::FLAG_COMMAND | mac::FLAG_CONTROL | 0x09)), []);
        assert_eq!(host.translate(&flags_event(mac::COMMAND, mac::FLAG_CONTROL | 0x01)), []);
        assert_eq!(host.translate(&flags_event(mac::CONTROL, 0)), [key(pc::LEFT_CONTROL, false)]);
    }

    #[test]
    fn a_keystroke_carries_the_modifiers_of_its_own_flags() {
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        // The Shift press was never seen, for example because the canvas gained focus while it was held.
        let ops = host.translate(&key_event(InputKind::KeyDown, C, mac::FLAG_SHIFT));
        assert_eq!(ops, [key(pc::LEFT_SHIFT, true), InjectOp::CapsLock(false), key(PC_C, true)]);
        // And a release that was missed does not leave Shift down for the next key.
        let ops = host.translate(&key_event(InputKind::KeyDown, 0x00, mac::FLAG_CAPS_LOCK));
        assert_eq!(ops, [key(pc::LEFT_SHIFT, false), InjectOp::CapsLock(true), key(PcKey::Scan { code: 0x1E, extended: false }, true)]);
    }

    #[test]
    fn older_viewers_without_device_bits_and_caps_lock_follow_the_general_flags() {
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        assert_eq!(host.translate(&flags_event(mac::RIGHT_OPTION, mac::FLAG_OPTION)), [key(pc::RIGHT_ALT, true)]);
        assert_eq!(host.translate(&flags_event(mac::RIGHT_OPTION, 0)), [key(pc::RIGHT_ALT, false)]);
        assert_eq!(host.translate(&flags_event(mac::CAPS_LOCK, mac::FLAG_CAPS_LOCK)), [InjectOp::CapsLock(true)]);
        assert_eq!(host.translate(&flags_event(63, 1 << 23)), []);
    }

    #[test]
    fn release_all_lets_go_of_keys_modifiers_and_buttons_once() {
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        host.translate(&flags_event(mac::SHIFT, mac::FLAG_SHIFT | 0x02));
        host.translate(&key_event(InputKind::KeyDown, C, mac::FLAG_SHIFT | 0x02));
        let mut press = RemoteInput::new(InputKind::Down);
        press.button = 1;
        host.translate(&press);
        assert_eq!(host.release_all(), [key(PC_C, false), key(pc::LEFT_SHIFT, false), InjectOp::Button { button: MouseButton::Right, down: false }]);
        assert_eq!(host.release_all(), []);
        // A release for a key that is no longer held injects nothing.
        assert_eq!(host.translate(&key_event(InputKind::KeyUp, C, 0)), []);
    }

    #[test]
    fn pointer_events_move_first_and_ignore_buttons_windows_does_not_have() {
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        let mut press = RemoteInput::new(InputKind::Down);
        (press.x, press.y, press.button) = (0.25, 0.75, 3);
        assert_eq!(host.translate(&press), [InjectOp::Move { x: 0.25, y: 0.75 }, InjectOp::Button { button: MouseButton::X1, down: true }]);
        press.button = 9;
        assert_eq!(host.translate(&press), [InjectOp::Move { x: 0.25, y: 0.75 }]);
    }

    #[test]
    fn scroll_accumulates_fractions_and_flips_the_horizontal_axis() {
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        let mut wheel = RemoteInput::new(InputKind::Scroll);
        (wheel.line_delta_x, wheel.line_delta_y) = (Some(0.0), Some(3.0));
        assert_eq!(host.translate(&wheel)[1], InjectOp::Wheel { vertical: 120, horizontal: 0 });

        let mut gesture = RemoteInput::new(InputKind::Scroll);
        (gesture.delta_x, gesture.delta_y) = (2.0, -0.5);
        assert_eq!(host.translate(&gesture)[1], InjectOp::Wheel { vertical: 0, horizontal: -3 });
        // -0.75 units carried over, another -0.75 makes one whole unit.
        gesture.delta_x = 0.0;
        assert_eq!(host.translate(&gesture)[1], InjectOp::Wheel { vertical: -1, horizontal: 0 });
        gesture.delta_y = 0.0;
        assert_eq!(host.translate(&gesture).len(), 1);
    }

    fn viewer(mapping: PcModifierMapping) -> ViewerInputTranslator {
        ViewerInputTranslator::new(mapping, DoubleClick { interval: Duration::from_millis(500), distance: 4 })
    }

    fn pc_event(key: PcKey, down: bool) -> PcKeyEvent {
        let PcKey::Scan { code, extended } = key else { panic!("scan code expected") };
        PcKeyEvent { scan_code: code, extended, virtual_key: 0, down, repeat: false }
    }

    #[test]
    fn control_c_on_a_pc_becomes_control_c_or_command_c_for_a_mac() {
        let mut standard = viewer(PcModifierMapping::Standard);
        let control = standard.key(pc_event(pc::LEFT_CONTROL, true), false).unwrap();
        assert_eq!((control.kind, control.key_code, control.flags), (InputKind::Flags, mac::CONTROL, mac::FLAG_CONTROL | 0x01));
        let c = standard.key(pc_event(PC_C, true), false).unwrap();
        assert_eq!((c.kind, c.key_code, c.flags), (InputKind::KeyDown, C, mac::FLAG_CONTROL | 0x01));

        let mut habit = viewer(PcModifierMapping::ControlAsCommand);
        let command = habit.key(pc_event(pc::LEFT_CONTROL, true), false).unwrap();
        assert_eq!((command.key_code, command.flags), (mac::COMMAND, mac::FLAG_COMMAND | 0x08));
        assert_eq!(habit.key(pc_event(pc::LEFT_CONTROL, true), false), None, "auto-repeat of a held modifier");
        let released = habit.key(pc_event(pc::LEFT_CONTROL, false), false).unwrap();
        assert_eq!((released.kind, released.key_code, released.flags), (InputKind::Flags, mac::COMMAND, 0));
    }

    #[test]
    fn viewer_events_are_what_a_mac_host_accepts_and_a_windows_host_reverses() {
        let mut viewer = viewer(PcModifierMapping::Standard);
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        let events = [
            viewer.key(pc_event(pc::LEFT_WINDOWS, true), false).unwrap(),
            viewer.key(pc_event(PC_C, true), false).unwrap(),
            viewer.key(pc_event(PC_C, false), false).unwrap(),
            viewer.key(pc_event(pc::LEFT_WINDOWS, false), false).unwrap(),
        ];
        let ops: Vec<InjectOp> = events
            .iter()
            .flat_map(|event| {
                event.validate().unwrap();
                host.translate(event)
            })
            .collect();
        assert_eq!(ops, [key(pc::LEFT_WINDOWS, true), InjectOp::CapsLock(false), key(PC_C, true), key(PC_C, false), key(pc::LEFT_WINDOWS, false)]);
    }

    #[test]
    fn navigation_keys_carry_the_flags_appkit_adds_and_special_keys_use_their_virtual_key() {
        let mut viewer = viewer(PcModifierMapping::Standard);
        let up = viewer.key(pc_event(PcKey::Scan { code: 0x48, extended: true }, true), false).unwrap();
        assert_eq!((up.key_code, up.flags), (0x7E, mac::FLAG_NUMERIC_PAD | mac::FLAG_FUNCTION));
        let keypad_8 = viewer.key(pc_event(PcKey::Scan { code: 0x48, extended: false }, true), false).unwrap();
        assert_eq!((keypad_8.key_code, keypad_8.flags), (0x5B, mac::FLAG_NUMERIC_PAD));
        let pause = PcKeyEvent { scan_code: 0x45, extended: false, virtual_key: pc::VK_PAUSE, down: true, repeat: false };
        assert_eq!(viewer.key(pause, false).unwrap().key_code, 0x71);
        let unknown = PcKeyEvent { scan_code: 0x7F, extended: true, virtual_key: 0xFF, down: true, repeat: false };
        assert_eq!(viewer.key(unknown, false), None);
    }

    #[test]
    fn caps_lock_reports_the_new_state_once_and_stays_in_later_flags() {
        let mut viewer = viewer(PcModifierMapping::Standard);
        let on = viewer.key(pc_event(pc::CAPS_LOCK, true), true).unwrap();
        assert_eq!((on.kind, on.key_code, on.flags), (InputKind::Flags, mac::CAPS_LOCK, mac::FLAG_CAPS_LOCK));
        assert_eq!(viewer.key(pc_event(pc::CAPS_LOCK, false), true), None);
        assert_eq!(viewer.key(pc_event(PC_C, true), true).unwrap().flags, mac::FLAG_CAPS_LOCK);
        let off = viewer.key(pc_event(pc::CAPS_LOCK, true), false).unwrap();
        assert_eq!(off.flags, 0);
    }

    #[test]
    fn presses_count_clicks_and_moves_become_drags_while_a_button_is_held() {
        let mut viewer = viewer(PcModifierMapping::Standard);
        let at = |milliseconds| Duration::from_millis(milliseconds);
        assert_eq!(viewer.pointer_move(0.1, 0.1).kind, InputKind::Move);
        assert_eq!(viewer.button(0, true, 0.5, 0.5, at(0), (100, 100)).clicks, 1);
        let drag = viewer.pointer_move(0.6, 0.5);
        assert_eq!((drag.kind, drag.button, drag.clicks), (InputKind::Drag, 0, 1));
        assert_eq!(viewer.button(0, false, 0.5, 0.5, at(50), (100, 100)).clicks, 1);
        let second = viewer.button(0, true, 0.5, 0.5, at(300), (102, 99));
        assert_eq!((second.kind, second.clicks), (InputKind::Down, 2));
        assert_eq!(viewer.button(0, false, 0.5, 0.5, at(350), (102, 99)).clicks, 2);
        assert_eq!(viewer.button(0, true, 0.5, 0.5, at(600), (102, 99)).clicks, 3);
        assert_eq!(viewer.button(0, true, 0.5, 0.5, at(700), (102, 99)).clicks, 1, "a fourth press starts over");
        assert_eq!(viewer.button(0, true, 0.5, 0.5, at(1300), (102, 99)).clicks, 1, "too late");
        assert_eq!(viewer.button(0, true, 0.5, 0.5, at(1400), (140, 99)).clicks, 1, "too far");
        assert_eq!(viewer.button(1, true, 0.5, 0.5, at(1450), (140, 99)).clicks, 1, "another button");
    }

    #[test]
    fn a_wheel_notch_is_three_lines_with_the_macos_sign_for_horizontal_movement() {
        let viewer = viewer(PcModifierMapping::Standard);
        let wheel = viewer.wheel(1.0, 0.5, 2.0, -1.0);
        assert_eq!((wheel.x, wheel.y), (1.0, 0.0));
        assert_eq!((wheel.line_delta_x, wheel.line_delta_y), (Some(-1.5), Some(3.0)));
        assert_eq!((wheel.delta_x, wheel.delta_y), (-18.0, 36.0));
        wheel.validate().unwrap();
        // A Windows host turns it back into the same notch.
        let mut host = HostInputTranslator::new(MacModifierMapping::Standard);
        assert_eq!(host.translate(&wheel)[1], InjectOp::Wheel { vertical: 120, horizontal: 60 });
    }

    #[test]
    fn releasing_control_ends_the_drag_and_the_click_sequence() {
        let mut viewer = viewer(PcModifierMapping::Standard);
        viewer.button(0, true, 0.5, 0.5, Duration::ZERO, (100, 100));
        viewer.release_all();
        assert_eq!(viewer.pointer_move(0.5, 0.5).kind, InputKind::Move);
        assert_eq!(viewer.button(0, true, 0.5, 0.5, Duration::from_millis(20), (100, 100)).clicks, 1);
    }
}
