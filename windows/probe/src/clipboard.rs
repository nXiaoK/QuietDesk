use crate::emit;
use quietdesk_core::clipboard::{Action, Exchange, Input, Kind, Payload, Revision, Role};
use quietdesk_core::clipboard_session::SessionClipboard;
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

#[derive(Default)]
struct Board {
    input: Option<mpsc::WeakSender<Input>>,
    token: u64,
    local: Option<Payload>,
    manifest: Option<Revision>,
    offer: Option<Revision>,
}

impl Board {
    fn copy(&mut self, kind: Kind, payload: Payload) -> Input {
        self.token += 1;
        self.local = Some(payload);
        self.manifest = None;
        self.offer = None;
        Input::LocalChanged { token: self.token, kind: Some(kind) }
    }
}

#[derive(Clone)]
pub struct SyntheticClipboard {
    directory: PathBuf,
    board: Arc<Mutex<Board>>,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
enum Command {
    CopyText { text: String },
    CopyPng { bytes: Vec<u8> },
    CopyFiles { names: Vec<String> },
    ClipboardPaste,
    ClipboardDecision { accept: bool },
}

impl SyntheticClipboard {
    pub fn new(directory: &str) -> Self {
        Self { directory: PathBuf::from(directory), board: Arc::default() }
    }

    pub fn open(&self, role: Role, enabled: bool) -> Option<SessionClipboard> {
        let exchange = Exchange::start(role, self.directory.join("received-by-probe"), enabled, true).ok()?;
        let weak_input = exchange.input.downgrade();
        *self.board.lock().unwrap() = Board { input: Some(weak_input.clone()), ..Board::default() };
        let board = self.board.clone();
        Some(SessionClipboard::new(exchange, move |action| {
            let Some(input) = weak_input.upgrade() else { return };
            let mut board = board.lock().unwrap();
            match action {
                Action::CountFileRoots { token } => {
                    if board.token == token
                        && let Some(Payload::Files(paths)) = board.local.as_ref()
                    {
                        let _ = input.try_send(Input::FileRootCount { token, count: Some(paths.len()) });
                    }
                }
                Action::Read { token, kind } => {
                    emit(json!({"event":"clipboardRead","kind":kind}));
                    let payload = if board.token == token { board.local.clone() } else { None };
                    let _ = input.try_send(Input::Read { token, payload });
                }
                Action::Advertise { revision, kind, file_root_count } => {
                    board.local = None;
                    board.manifest = Some(revision);
                    let mut event = json!({"event":"clipboardManifest","kind":kind,"revision":revision});
                    if let Some(count) = file_root_count {
                        event["fileRootCount"] = json!(count);
                    }
                    emit(event);
                }
                Action::FileOffer(offer) => {
                    board.offer = Some(offer.revision);
                    emit(json!({"event":"clipboardOffer","count":offer.roots,"bytes":offer.bytes,"explicitDrop":offer.explicit_drop}));
                }
                Action::Apply { revision, payload, explicit_drop, .. } => {
                    let content = match &payload {
                        Payload::Text(text) => json!({"text":text}),
                        Payload::Png(bytes) => json!({"bytes":bytes}),
                        Payload::Files(paths) => json!({"paths":paths}),
                    };
                    board.offer = None;
                    board.manifest = None;
                    if !explicit_drop {
                        board.local = Some(payload);
                        board.token += 1;
                    }
                    emit(json!({"event":"clipboardApplied","content":content,"explicitDrop":explicit_drop}));
                    let _ = input.try_send(Input::Applied { revision, success: true });
                }
                Action::Clear => {
                    board.manifest = None;
                    board.offer = None;
                    emit(json!({"event":"clipboardCleared"}));
                }
                Action::Status(message) => emit(json!({"event":"clipboardStatus","message":message})),
            }
        }))
    }

    pub fn command(&self, line: &Value) -> bool {
        let Ok(command) = serde_json::from_value::<Command>(line.clone()) else { return false };
        let mut board = self.board.lock().unwrap();
        let Some(input) = board.input.as_ref().and_then(mpsc::WeakSender::upgrade) else {
            emit(json!({"event":"invalidCommand","error":"no clipboard session"}));
            return true;
        };
        let event = match command {
            Command::ClipboardPaste => board.manifest.map(Input::Paste),
            Command::ClipboardDecision { accept } => board.offer.map(|revision| Input::Decision { revision, accept }),
            Command::CopyText { text } => Some(board.copy(Kind::Text, Payload::Text(text))),
            Command::CopyPng { bytes } => Some(board.copy(Kind::Png, Payload::Png(bytes))),
            Command::CopyFiles { names } => {
                if !names.iter().all(|name| Path::new(name).file_name() == Some(name.as_ref())) {
                    emit(json!({"event":"invalidCommand","error":"file names must be fixture roots"}));
                    return true;
                }
                let paths = names.iter().map(|name| self.directory.join(name)).collect();
                Some(board.copy(Kind::Files, Payload::Files(paths)))
            }
        };
        if event.is_none_or(|event| input.try_send(event).is_err()) {
            emit(json!({"event":"invalidCommand","error":"clipboard action unavailable"}));
        }
        true
    }
}
