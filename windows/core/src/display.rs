//! Display selection and message 37 from DisplaySelection.swift.

use crate::error::{DeskError, Result};
use crate::messages::VideoStreamState;
use crate::wire::{Message, MessageKind};
use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const MAX_DISPLAYS: usize = 16;
pub const MIN_DISPLAY_DIMENSION: u32 = 2;
pub const MAX_DISPLAY_DIMENSION: u32 = 16_384;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteDisplayInfo {
    pub id: u32,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub is_main: bool,
}

impl RemoteDisplayInfo {
    pub fn new(id: u32, name: &str, width: u32, height: u32, is_main: bool) -> Self {
        Self { id, name: name.graphemes(true).take(96).collect(), width, height, is_main }
    }
}

pub(crate) fn validate_list(displays: &[RemoteDisplayInfo], selected: Option<u32>) -> Result<()> {
    if !(1..=MAX_DISPLAYS).contains(&displays.len()) {
        return Err(DeskError::invalid("远端显示器列表数量无效"));
    }
    for (index, display) in displays.iter().enumerate() {
        if display.id == 0
            || display.name.trim().is_empty()
            || display.name.graphemes(true).nth(96).is_some()
            || !(MIN_DISPLAY_DIMENSION..=MAX_DISPLAY_DIMENSION).contains(&display.width)
            || !(MIN_DISPLAY_DIMENSION..=MAX_DISPLAY_DIMENSION).contains(&display.height)
        {
            return Err(DeskError::invalid("远端显示器信息无效"));
        }
        if displays[..index].iter().any(|other| other.id == display.id) {
            return Err(DeskError::invalid("远端显示器列表包含重复标识"));
        }
    }
    if selected.is_some_and(|id| !displays.iter().any(|display| display.id == id)) {
        return Err(DeskError::invalid("当前共享显示器不在可用列表中"));
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostDisplays {
    pub displays: Vec<RemoteDisplayInfo>,
    /// The captured display, or the platform's available replacement if that display disappeared.
    pub selected_display_id: u32,
    /// The active source disappeared or its origin or pixel dimensions changed.
    pub needs_restart: bool,
}

impl HostDisplays {
    pub fn validate(&self) -> Result<()> {
        validate_list(&self.displays, Some(self.selected_display_id))
    }
}

pub enum DisplaySwitch {
    Applied(VideoStreamState),
    /// Capture, the encoder, the input bounds and the frame sink still use the previous screen.
    Retained(String),
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(tag = "operation", rename_all = "lowercase")]
pub enum DisplayControl {
    Subscribe,
    Select {
        id: Uuid,
        #[serde(rename = "displayID")]
        display_id: u32,
    },
    State {
        displays: Vec<RemoteDisplayInfo>,
        #[serde(rename = "selectedDisplayID")]
        selected: u32,
        #[serde(rename = "videoState", skip_serializing_if = "Option::is_none")]
        video_state: Option<VideoStreamState>,
    },
    Result {
        id: Uuid,
        displays: Vec<RemoteDisplayInfo>,
        #[serde(rename = "selectedDisplayID")]
        selected: u32,
        #[serde(rename = "videoState")]
        video_state: VideoStreamState,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

impl DisplayControl {
    pub fn message(&self) -> Result<Message> {
        Message::json(MessageKind::DisplayControl, self)
    }

    pub fn read(message: &Message) -> Result<Self> {
        #[derive(Deserialize)]
        struct Fields {
            operation: String,
            id: Option<Uuid>,
            #[serde(rename = "displayID")]
            target: Option<u32>,
            #[serde(rename = "selectedDisplayID")]
            selected: Option<u32>,
            displays: Option<Vec<RemoteDisplayInfo>>,
            #[serde(rename = "videoState")]
            video: Option<VideoStreamState>,
            error: Option<String>,
        }
        let Fields { operation, id, target, selected, displays, video, error } = message.read_json()?;
        match (operation.as_str(), id, target, selected, displays, video, error) {
            ("subscribe", None, None, None, None, None, None) => Ok(Self::Subscribe),
            ("select", Some(id), Some(display_id @ 1..), None, None, None, None) => Ok(Self::Select { id, display_id }),
            ("state", None, None, Some(selected), Some(displays), video_state, None) => {
                validate_list(&displays, Some(selected))?;
                if let Some(state) = video_state {
                    state.validate()?;
                }
                Ok(Self::State { selected, displays, video_state })
            }
            ("result", Some(id), None, Some(selected), Some(displays), Some(video_state), error) => {
                validate_list(&displays, Some(selected))?;
                video_state.validate()?;
                if error.as_ref().is_some_and(|reason| reason.graphemes(true).nth(512).is_some()) {
                    return Err(DeskError::invalid("显示器切换错误信息过长"));
                }
                Ok(Self::Result { id, selected, displays, video_state, error })
            }
            _ => Err(DeskError::invalid("显示器控制消息字段无效")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_names_use_swift_character_boundaries_and_keep_the_selected_id_on_the_wire() {
        let composed = "👩🏽‍💻".repeat(96);
        let display = RemoteDisplayInfo::new(0x8000_0302, &format!("{composed}x"), 5120, 2880, true);
        assert_eq!(display.name, composed);
        let state = DisplayControl::State { selected: display.id, displays: vec![display], video_state: None };
        let message = state.message().unwrap();
        let json: serde_json::Value = message.read_json().unwrap();
        assert_eq!(json["selectedDisplayID"], 0x8000_0302u32);
        assert!(json.get("videoState").is_none());
        assert_eq!(DisplayControl::read(&message).unwrap(), state);
    }

    #[test]
    fn a_display_subscription_ignores_extensions_but_rejects_fields_of_other_operations() {
        let read = |value| DisplayControl::read(&Message::json(MessageKind::DisplayControl, &value).unwrap());
        assert_eq!(read(serde_json::json!({"operation": "subscribe", "extension":42})).unwrap(), DisplayControl::Subscribe);
        assert!(read(serde_json::json!({"operation":"subscribe", "selectedDisplayID":17})).is_err());
    }

    #[test]
    fn a_display_state_has_a_unique_entry_for_its_selected_screen() {
        let screen = RemoteDisplayInfo::new(1, "内置屏", 1080, 1920, true);
        assert!(validate_list(std::slice::from_ref(&screen), Some(2)).is_err());
        assert!(validate_list(&[screen.clone(), screen], Some(1)).is_err());
    }
}
