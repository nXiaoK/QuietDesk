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

    pub(crate) fn is_bulk(kind: MessageKind) -> bool {
        kind != MessageKind::ClipboardSettings && Self::accepts(kind)
    }

    pub(crate) async fn next(session: &mut Option<Self>, control: &PeerHandle, bulk: Option<&PeerHandle>) -> Result<Option<String>> {
        let Some(active) = session else { return std::future::pending().await };
        let output = active.exchange.output.recv().await.ok_or_else(|| DeskError::platform("剪贴板会话已结束"))?;
        match output {
            Output::Send(message) => {
                // Install the negotiated receiver before its first manifest, even when bulk is already bound.
                let peer = if message.kind != MessageKind::ClipboardManifest && Self::is_bulk(message.kind) { bulk.unwrap_or(control) } else { control };
                peer.send(&message)?;
            }
            Output::Native(Action::Status(status)) => return Ok(Some(status.chars().filter(|c| !c.is_control()).take(256).collect())),
            Output::Native(action) => (active.native)(action),
            Output::ProtocolError(reason) => return Err(DeskError::invalid(reason)),
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{peer, wire};
    use std::time::Duration;
    use tokio::io::{DuplexStream, duplex};
    use tokio::sync::mpsc;

    async fn next_message(reader: &mut DuplexStream) -> Message {
        loop {
            let message = wire::read_message(reader).await.unwrap().unwrap();
            if message.kind != MessageKind::Ping {
                return message;
            }
        }
    }

    #[tokio::test]
    async fn settings_and_manifest_arrive_in_order_while_file_data_uses_the_bound_bulk_lane() {
        let (control_socket, mut control_wire) = duplex(32 * 1024);
        let (bulk_socket, mut bulk_wire) = duplex(32 * 1024);
        let (control, _control_events) = peer::spawn(control_socket, Default::default());
        let (bulk, _bulk_events) = peer::spawn(bulk_socket, Default::default());
        let (input, _requests) = mpsc::channel(1);
        let (events, output) = mpsc::channel(3);
        let mut session = Some(SessionClipboard::new(Exchange { input, output }, |_| {}));
        let settings = Message::new(MessageKind::ClipboardSettings, vec![]);
        let manifest = Message::new(MessageKind::ClipboardManifest, vec![b'a'; 8192]);
        let chunk = Message::new(MessageKind::ClipboardChunk, vec![42; 1024]);
        for message in [&settings, &manifest, &chunk] {
            events.try_send(Output::Send(message.clone())).unwrap();
            SessionClipboard::next(&mut session, &control, Some(&bulk)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            assert_eq!(next_message(&mut control_wire).await, settings);
            assert_eq!(next_message(&mut control_wire).await, manifest);
            assert_eq!(next_message(&mut bulk_wire).await, chunk);
        })
        .await
        .expect("clipboard messages must reach their respective lanes");
        assert!(SessionClipboard::is_bulk(MessageKind::ClipboardManifest), "older peers can still send manifests on bulk");
    }
}
