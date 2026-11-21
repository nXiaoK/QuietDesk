//! JSON control messages. Field names and optionality follow `Sources/QuietDeskCore`; a field the other
//! side does not know is ignored there, and a field missing here keeps the older behaviour.

use crate::error::{DeskError, Result};
use crate::wire;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamSettings {
    pub longest_edge: i64,
    pub frames_per_second: i64,
    pub megabits: i64,
}

impl StreamSettings {
    pub const LEGACY_LONGEST_EDGES: [i64; 4] = [1280, 1920, 2560, 3840];
    pub const NATIVE_LONGEST_EDGE: i64 = 8192;
    pub const FRAME_RATES: [i64; 10] = [10, 15, 30, 60, 75, 90, 120, 144, 165, 240];
    pub const LEGACY_BIT_RATES: [i64; 6] = [1, 2, 3, 5, 8, 12];
    pub const BIT_RATES: [i64; 18] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100];
    const MAXIMUM_PIXELS: f64 = 36_000_000.0;

    pub const fn new(longest_edge: i64, frames_per_second: i64, megabits: i64) -> Self {
        Self { longest_edge, frames_per_second, megabits }
    }

    /// Values a stream settings request or result may carry.
    pub fn validate_control_values(&self) -> Result<()> {
        let edge = Self::LEGACY_LONGEST_EDGES.contains(&self.longest_edge) || self.longest_edge == Self::NATIVE_LONGEST_EDGE;
        if edge && Self::FRAME_RATES.contains(&self.frames_per_second) && Self::BIT_RATES.contains(&self.megabits) {
            Ok(())
        } else {
            Err(DeskError::invalid("不支持的画质参数"))
        }
    }

    /// The values every released viewer accepts in `Hello.settings`.
    pub fn legacy_compatible(&self) -> Self {
        Self::new(self.longest_edge.min(3840), self.frames_per_second.min(30), self.megabits.min(12))
    }

    pub fn extended_compatible(&self) -> Self {
        Self::new(self.longest_edge, self.frames_per_second.min(30), self.megabits.min(30))
    }

    pub fn high_refresh_compatible(&self) -> Self {
        Self::new(self.longest_edge, self.frames_per_second.min(60), self.megabits)
    }

    /// Lowers each value to the nearest allowed value that does not exceed `limit`.
    pub fn limited_to(&self, limit: &Self) -> Self {
        fn cap(value: i64, limit: i64, allowed: &[i64]) -> i64 {
            let ceiling = value.min(limit);
            allowed.iter().copied().filter(|candidate| *candidate <= ceiling).max().unwrap_or(allowed[0])
        }
        let mut edges = Self::LEGACY_LONGEST_EDGES.to_vec();
        edges.push(Self::NATIVE_LONGEST_EDGE);
        Self::new(
            cap(self.longest_edge, limit.longest_edge, &edges),
            cap(self.frames_per_second, limit.frames_per_second, &Self::FRAME_RATES),
            cap(self.megabits, limit.megabits, &Self::BIT_RATES),
        )
    }

    /// The encoded size for a source of `width` by `height`: never enlarged, even on both axes.
    pub fn dimensions(&self, width: u32, height: u32) -> (u32, u32) {
        let (source_width, source_height) = (f64::from(width.max(1)), f64::from(height.max(1)));
        let edge = self.longest_edge.min(Self::NATIVE_LONGEST_EDGE) as f64;
        let scale = 1f64.min(edge / source_width.max(source_height)).min((Self::MAXIMUM_PIXELS / (source_width * source_height)).sqrt());
        let even = |value: u32| (((f64::from(value) * scale) as u32) / 2 * 2).max(2);
        (even(width), even(height))
    }

    pub fn summary(&self) -> String {
        let edge = if self.longest_edge == Self::NATIVE_LONGEST_EDGE { "原分辨率".to_string() } else { self.longest_edge.to_string() };
        format!("{edge} / {} fps / {} Mbps", self.frames_per_second, self.megabits)
    }
}

/// The first message of a session, sent by the host once it knows the size it will encode.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    pub version: i64,
    pub name: String,
    pub width: i64,
    pub height: i64,
    pub settings: StreamSettings,
    pub can_control: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live_settings: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control_status_updates: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extended_video_settings: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_settings: Option<StreamSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub high_refresh_video_settings: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_high_refresh_settings: Option<StreamSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_pause: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_termination_v1: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_stream_negotiation_v1: Option<bool>,
}

impl Hello {
    pub fn validate(&self) -> Result<()> {
        let size = (2..=8192).contains(&self.width) && (2..=8192).contains(&self.height) && self.width * self.height <= 36_000_000;
        if self.version != wire::VERSION || !size || !(1..=60).contains(&self.settings.frames_per_second) || !(1..=30).contains(&self.settings.megabits) {
            return Err(DeskError::invalid("远端版本或画面参数不兼容"));
        }
        for preferred in [
            self.preferred_settings.filter(|_| self.extended_video_settings == Some(true)),
            self.preferred_high_refresh_settings.filter(|_| self.high_refresh_video_settings == Some(true)),
        ]
        .into_iter()
        .flatten()
        {
            preferred.validate_control_values()?;
            if preferred.frames_per_second > 60 {
                return Err(DeskError::invalid("兼容画质字段的帧率不能超过 60 fps"));
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlStatus {
    pub can_control: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoStreamState {
    pub settings: StreamSettings,
    pub width: i64,
    pub height: i64,
}

impl VideoStreamState {
    pub fn validate(&self) -> Result<()> {
        self.settings.validate_control_values()?;
        let even = |value: i64| (2..=8192).contains(&value) && value % 2 == 0;
        if even(self.width) && even(self.height) && self.width * self.height <= 36_000_000 {
            Ok(())
        } else {
            Err(DeskError::invalid("画质回复的分辨率无效"))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VideoCodec {
    H264,
    Hevc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChromaSubsampling {
    Yuv420,
    Yuv444,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamSettingsRequest {
    pub id: Uuid,
    pub settings: StreamSettings,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<VideoCodec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chroma_subsampling: Option<ChromaSubsampling>,
}

impl StreamSettingsRequest {
    pub fn new(settings: StreamSettings) -> Self {
        Self { id: Uuid::new_v4(), settings, codec: None, chroma_subsampling: None }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamSettingsResult {
    pub id: Uuid,
    pub state: VideoStreamState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Echoed only to a request that named a codec; missing means H.264.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<VideoCodec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chroma_subsampling: Option<ChromaSubsampling>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPauseRequest {
    pub id: Uuid,
    pub paused: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPauseResult {
    pub id: Uuid,
    pub paused: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminationOperation {
    Subscribe,
    Ended,
}

/// A host that advertised `sessionTerminationV1` tells a subscribed viewer when its user ends the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionTermination {
    pub operation: TerminationOperation,
}

pub const HOST_ENDED_REASON: &str = "被控端已结束本次连接";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InputKind {
    Move,
    Drag,
    Down,
    Up,
    Scroll,
    Magnify,
    Rotate,
    SmartMagnify,
    KeyDown,
    KeyUp,
    Flags,
    SwitchInputSource,
    ToggleCapsLock,
}

/// One pointer or keyboard event. Positions are fractions of the shared display, key codes are macOS
/// virtual key codes and `flags` are `NSEvent.ModifierFlags` bits, whichever platform sends them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteInput {
    pub kind: InputKind,
    pub x: f64,
    pub y: f64,
    pub button: i64,
    pub key_code: u16,
    pub flags: u64,
    pub delta_x: f64,
    pub delta_y: f64,
    pub clicks: i64,
    pub is_repeat: bool,
    /// Line deltas of a wheel without precise deltas; `delta_x`/`delta_y` then carry the pixel equivalent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_delta_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_delta_y: Option<f64>,
}

impl RemoteInput {
    pub const MAXIMUM_LINE_DELTA: f64 = 250.0;
    pub const MAXIMUM_PIXEL_DELTA: f64 = 3000.0;
    pub const MAXIMUM_BUTTON: i64 = 31;
    pub const MAXIMUM_KEY_CODE: u16 = 127;

    pub fn new(kind: InputKind) -> Self {
        Self {
            kind,
            x: 0.0,
            y: 0.0,
            button: 0,
            key_code: 0,
            flags: 0,
            delta_x: 0.0,
            delta_y: 0.0,
            clicks: 1,
            is_repeat: false,
            line_delta_x: None,
            line_delta_y: None,
        }
    }

    pub fn validate(&self) -> Result<()> {
        let unit = |value: f64| value.is_finite() && (0.0..=1.0).contains(&value);
        let bounded = |value: f64, limit: f64| value.is_finite() && value.abs() <= limit;
        let lines = match (self.line_delta_x, self.line_delta_y) {
            (None, None) => true,
            (Some(x), Some(y)) => self.kind == InputKind::Scroll && bounded(x, Self::MAXIMUM_LINE_DELTA) && bounded(y, Self::MAXIMUM_LINE_DELTA),
            _ => false,
        };
        if unit(self.x)
            && unit(self.y)
            && (0..=Self::MAXIMUM_BUTTON).contains(&self.button)
            && self.key_code <= Self::MAXIMUM_KEY_CODE
            && (0..=3).contains(&self.clicks)
            && bounded(self.delta_x, Self::MAXIMUM_PIXEL_DELTA)
            && bounded(self.delta_y, Self::MAXIMUM_PIXEL_DELTA)
            && lines
        {
            Ok(())
        } else {
            Err(DeskError::invalid("远端输入参数无效"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dimensions_match_the_macos_rounding() {
        // (longest edge, source width, source height, width, height) as StreamSettings.dimensions computes them in Swift.
        let expected = [
            (1920, 3840, 2160, 1920, 1080),
            (1920, 2560, 1440, 1920, 1080),
            (1920, 1366, 768, 1366, 768),
            (1920, 1367, 769, 1366, 768),
            (1280, 3024, 1964, 1280, 830),
            (8192, 8192, 8192, 6000, 6000),
            (2560, 3456, 2234, 2560, 1654),
            (1920, 5120, 2880, 1920, 1080),
            (3840, 5120, 1440, 3840, 1080),
            (1280, 1920, 1200, 1280, 800),
            (2560, 3840, 2400, 2560, 1600),
            (1920, 3440, 1440, 1920, 802),
            (1920, 1080, 1920, 1080, 1920),
            (1280, 2880, 1800, 1280, 800),
            (1920, 3024, 1964, 1920, 1246),
            (2560, 3024, 1964, 2560, 1662),
            (1280, 3456, 2234, 1280, 826),
            (1920, 2880, 1864, 1920, 1242),
        ];
        for (edge, source_width, source_height, width, height) in expected {
            assert_eq!(StreamSettings::new(edge, 30, 8).dimensions(source_width, source_height), (width, height));
        }
    }

    #[test]
    fn limits_pick_allowed_values_only() {
        let limit = StreamSettings::new(2560, 60, 30);
        assert_eq!(StreamSettings::new(8192, 240, 100).limited_to(&limit), limit);
        assert_eq!(StreamSettings::new(1920, 30, 8).limited_to(&limit), StreamSettings::new(1920, 30, 8));
        let odd_limit = StreamSettings::new(3000, 50, 7);
        assert_eq!(StreamSettings::new(8192, 240, 100).limited_to(&odd_limit), StreamSettings::new(2560, 30, 6));
    }

    #[test]
    fn hello_omits_unset_capabilities_and_reads_unknown_fields() {
        let hello = Hello {
            version: 1,
            name: "PC".into(),
            width: 1920,
            height: 1080,
            settings: StreamSettings::new(1920, 30, 8),
            can_control: true,
            live_settings: Some(true),
            control_status_updates: None,
            extended_video_settings: None,
            preferred_settings: None,
            high_refresh_video_settings: None,
            preferred_high_refresh_settings: None,
            session_pause: None,
            session_termination_v1: None,
            initial_stream_negotiation_v1: None,
        };
        let json = serde_json::to_string(&hello).unwrap();
        assert_eq!(
            json,
            r#"{"version":1,"name":"PC","width":1920,"height":1080,"settings":{"longestEdge":1920,"framesPerSecond":30,"megabits":8},"canControl":true,"liveSettings":true}"#
        );
        let from_mac = r#"{"version":1,"name":"Mac","width":2,"height":2,"canControl":false,"mediaTransportV1":true,
            "settings":{"megabits":3,"longestEdge":1920,"framesPerSecond":15},"displays":[{"id":1}],"sessionTerminationV1":true}"#;
        let parsed: Hello = serde_json::from_str(from_mac).unwrap();
        assert_eq!(parsed.session_termination_v1, Some(true));
        assert_eq!(parsed.live_settings, None);
        parsed.validate().unwrap();
    }

    #[test]
    fn hello_rejects_values_released_viewers_reject() {
        let mut hello: Hello = serde_json::from_str(
            r#"{"version":1,"name":"Mac","width":1920,"height":1080,"canControl":true,
                "settings":{"megabits":12,"longestEdge":1920,"framesPerSecond":30}}"#,
        )
        .unwrap();
        hello.validate().unwrap();
        hello.settings.megabits = 60;
        assert!(hello.validate().is_err());
        hello.settings.megabits = 12;
        hello.version = 2;
        assert!(hello.validate().is_err());
    }

    #[test]
    fn input_uses_the_macos_field_names_and_requires_all_base_fields() {
        let mut input = RemoteInput::new(InputKind::KeyDown);
        input.key_code = 8;
        input.flags = 1 << 20;
        assert_eq!(
            serde_json::to_string(&input).unwrap(),
            r#"{"kind":"keyDown","x":0.0,"y":0.0,"button":0,"keyCode":8,"flags":1048576,"deltaX":0.0,"deltaY":0.0,"clicks":1,"isRepeat":false}"#
        );
        let from_mac = r#"{"kind":"scroll","x":0.5,"y":1,"button":0,"keyCode":0,"flags":256,"deltaX":0,"deltaY":-36,
            "clicks":1,"isRepeat":false,"lineDeltaX":0,"lineDeltaY":-3,"pointerSequence":7}"#;
        let parsed: RemoteInput = serde_json::from_str(from_mac).unwrap();
        assert_eq!(parsed.kind, InputKind::Scroll);
        assert_eq!(parsed.line_delta_y, Some(-3.0));
        parsed.validate().unwrap();
        assert!(serde_json::from_str::<RemoteInput>(r#"{"kind":"keyDown","keyCode":8}"#).is_err());
        assert!(serde_json::from_str::<RemoteInput>(&from_mac.replace("scroll", "teleport")).is_err());
    }

    #[test]
    fn input_validation_bounds_what_the_host_injects() {
        let mut input = RemoteInput::new(InputKind::Move);
        input.x = 1.5;
        assert!(input.validate().is_err());
        input.x = f64::NAN;
        assert!(input.validate().is_err());
        input.x = 1.0;
        input.validate().unwrap();
        input.key_code = 128;
        assert!(input.validate().is_err());
        input.key_code = 0;
        input.line_delta_x = Some(1.0);
        assert!(input.validate().is_err());
    }

    #[test]
    fn termination_and_identifiers_use_the_macos_spelling() {
        let subscribe = SessionTermination { operation: TerminationOperation::Subscribe };
        assert_eq!(serde_json::to_string(&subscribe).unwrap(), r#"{"operation":"subscribe"}"#);
        let request: StreamSettingsRequest = serde_json::from_str(
            r#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","settings":{"longestEdge":8192,"framesPerSecond":60,"megabits":100},
                "codec":"hevc","chromaSubsampling":"yuv444","cursorRequestID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","independentCursor":true}"#,
        )
        .unwrap();
        assert_eq!(request.codec, Some(VideoCodec::Hevc));
        assert_eq!(request.chroma_subsampling, Some(ChromaSubsampling::Yuv444));
        request.settings.validate_control_values().unwrap();
    }
}
