//! Connects one authenticated peer to its clipboard exchange and native clipboard owner.

use crate::clipboard::{Action, Exchange, Input, Output};
use crate::error::{DeskError, Result};
use crate::peer::PeerHandle;
use crate::wire::{Message, MessageKind};

pub struct SessionClipboard {
    // Closing the native owner releases the sender it uses to notify the exchange.
    native: Box<dyn FnMut(Action) + Send>,
    exchange: Exchange,
}

impl SessionClipboard {
    pub fn new(exchange: Exchange, native: impl FnMut(Action) + Send + 'static) -> Self {
        Self { native: Box::new(native), exchange }
    }

    pub(crate) fn receive(&self, message: Message) -> Result<()> {
        self.input(Input::Peer(message))
    }

    pub(crate) fn preferences(&self, enabled: bool, receives: bool) -> Result<()> {
        self.input(Input::Preferences { enabled, receives })
    }

    fn input(&self, event: Input) -> Result<()> {
        self.exchange.input.try_send(event).map_err(|error| match error {
            tokio::sync::mpsc::error::TrySendError::Full(_) => DeskError::invalid("剪贴板请求过多"),
            tokio::sync::mpsc::error::TrySendError::Closed(_) => DeskError::platform("剪贴板会话已结束"),
        })
    }

    pub(crate) fn accepts(kind: MessageKind) -> bool {
        matches!(
            kind,
            MessageKind::ClipboardSettings
                | MessageKind::ClipboardBegin
                | MessageKind::ClipboardEntry
                | MessageKind::ClipboardChunk
                | MessageKind::ClipboardEnd
                | MessageKind::ClipboardReceipt
                | MessageKind::ClipboardCancel
                | MessageKind::ClipboardManifest
                | MessageKind::ClipboardPull
        )
    }

    pub(crate) async fn next(session: &mut Option<Self>, peer: &PeerHandle) -> Result<Option<String>> {
        let Some(active) = session else { return std::future::pending().await };
        let output = active.exchange.output.recv().await.ok_or_else(|| DeskError::platform("剪贴板会话已结束"))?;
        match output {
            Output::Send(message) => peer.send(&message)?,
            Output::Native(Action::Status(status)) => return Ok(Some(status.chars().filter(|c| !c.is_control()).take(256).collect())),
            Output::Native(action) => (active.native)(action),
            Output::ProtocolError(reason) => return Err(DeskError::invalid(reason)),
        }
        Ok(None)
    }
}
