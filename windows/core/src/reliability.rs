//! Reconnects a viewer to the same target while its window or probe remains open.

use crate::error::Result;
use crate::media::DecodeReceipt;
use crate::messages::StreamSettings;
use crate::peer::{PeerEvent, PeerHandle};
use crate::viewer::{self, ViewerCommand, ViewerEnd, ViewerPlatform};
use std::future::Future;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

const STABLE_CONNECTION: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub enum RetryStatus {
    Waiting { attempt: u32, deadline: Instant, reason: String },
    Connecting { attempt: u32 },
    Deferred { reason: String },
}

#[derive(Debug)]
pub enum ViewerControl {
    Session {
        sent: Instant,
        command: ViewerCommand,
    },
    RetryNow,
    AutoReconnect(bool),
    /// An unattended viewer defers network recovery until the window is attended again.
    Idle(bool),
}

impl From<ViewerCommand> for ViewerControl {
    fn from(command: ViewerCommand) -> Self {
        Self::Session { sent: Instant::now(), command }
    }
}

#[derive(Default)]
struct RetryBackoff {
    attempt: u32,
}

impl RetryBackoff {
    fn next(&mut self) -> Duration {
        let delay = (1u64 << self.attempt.min(5)).min(30);
        self.attempt = self.attempt.saturating_add(1);
        Duration::from_secs(delay)
    }

    fn finished(&mut self, progress: &AttemptProgress) {
        if let (Some(start), Some(end)) = (progress.hello.get(), progress.end.get())
            && end.duration_since(*start) >= STABLE_CONNECTION
        {
            self.attempt = 0;
        }
    }
}

#[derive(Default)]
pub(crate) struct AttemptProgress {
    pub(crate) hello: OnceLock<Instant>,
    pub(crate) end: OnceLock<Instant>,
}

/// The command queue and negotiated lifetime of one authenticated connection.
pub struct Attempt {
    pub(crate) quality: StreamSettings,
    pub(crate) commands: mpsc::UnboundedReceiver<ViewerCommand>,
    pub(crate) progress: Arc<AttemptProgress>,
}

impl Attempt {
    pub(crate) fn new(quality: StreamSettings, commands: mpsc::UnboundedReceiver<ViewerCommand>) -> Self {
        Self { quality, commands, progress: Arc::default() }
    }

    pub async fn run<P: ViewerPlatform>(
        self,
        peer: PeerHandle,
        incoming: mpsc::Receiver<PeerEvent>,
        platform: &mut P,
        acknowledgements: mpsc::UnboundedReceiver<DecodeReceipt>,
    ) -> ViewerEnd {
        viewer::run_attempt(peer, incoming, platform, self, acknowledgements).await
    }
}

struct Supervisor {
    controls: mpsc::UnboundedReceiver<ViewerControl>,
    quality: StreamSettings,
    enabled: bool,
    idle: bool,
}

enum Action {
    Continue,
    RetryNow,
    AttentionChanged,
    Stop(ViewerEnd),
}

impl Supervisor {
    async fn control(&mut self, recovering: bool, active: Option<(&AttemptProgress, &mpsc::UnboundedSender<ViewerCommand>)>) -> Action {
        match self.controls.recv().await {
            Some(ViewerControl::RetryNow) => Action::RetryNow,
            Some(ViewerControl::AutoReconnect(enabled)) => {
                self.enabled = enabled;
                if !enabled && recovering && active.is_none_or(|(progress, _)| progress.hello.get().is_none()) {
                    return Action::Stop(ViewerEnd::stopped("已关闭自动重连"));
                }
                Action::Continue
            }
            Some(ViewerControl::Idle(idle)) => {
                if std::mem::replace(&mut self.idle, idle) != idle {
                    Action::AttentionChanged
                } else {
                    Action::Continue
                }
            }
            Some(ViewerControl::Session { command: ViewerCommand::Disconnect, .. }) | None => Action::Stop(ViewerEnd::stopped("已断开连接")),
            Some(ViewerControl::Session { command, sent }) => {
                let forward = if let ViewerCommand::Quality(settings) = &command {
                    self.quality = *settings;
                    true
                } else {
                    active.is_some_and(|(progress, _)| progress.hello.get().is_some_and(|hello| sent >= *hello))
                };
                if let Some((_, commands)) = active.filter(|_| forward) {
                    let _ = commands.send(command);
                }
                Action::Continue
            }
        }
    }

    async fn wait(&mut self, deadline: Instant, attempt: u32, reason: &str, notify: &mut impl FnMut(RetryStatus)) -> std::result::Result<(), ViewerEnd> {
        loop {
            if self.idle {
                notify(RetryStatus::Deferred { reason: reason.into() });
            } else {
                notify(RetryStatus::Waiting { attempt, deadline, reason: reason.into() });
            }
            loop {
                tokio::select! {
                    biased;
                    action = self.control(true, None) => match action {
                        Action::Stop(end) => return Err(end),
                        Action::RetryNow => return Ok(()),
                        Action::AttentionChanged if !self.idle => return Ok(()),
                        Action::AttentionChanged => break,
                        Action::Continue => {}
                    },
                    _ = tokio::time::sleep_until(deadline.into()), if !self.idle => return Ok(()),
                }
            }
        }
    }
}

/// Drives both connection establishment and the session. The caller retains its window/last picture
/// and supplies fresh platform resources per attempt. A session callback finishes after its workers exit.
pub async fn run<T, C, S>(
    quality: StreamSettings,
    auto_reconnect: bool,
    controls: mpsc::UnboundedReceiver<ViewerControl>,
    mut notify: impl FnMut(RetryStatus),
    mut connect: impl FnMut() -> C,
    mut session: impl FnMut(T, Attempt) -> S,
) -> ViewerEnd
where
    C: Future<Output = Result<T>>,
    S: Future<Output = ViewerEnd>,
{
    let mut supervisor = Supervisor { controls, quality, enabled: auto_reconnect, idle: false };
    let mut backoff = RetryBackoff::default();
    let mut last_failure: Option<ViewerEnd> = None;
    loop {
        if let Some(end) = &last_failure {
            let deadline = Instant::now() + backoff.next();
            if let Err(stopped) = supervisor.wait(deadline, backoff.attempt, &end.reason, &mut notify).await {
                return stopped;
            }
            notify(RetryStatus::Connecting { attempt: backoff.attempt });
        }

        let (commands, queue) = mpsc::unbounded_channel();
        let attempt = Attempt::new(supervisor.quality, queue);
        let progress = attempt.progress.clone();
        let (cancel, cancelled) = oneshot::channel::<()>();
        let connection = async {
            let stream = tokio::select! {
                biased;
                _ = cancelled => return ViewerEnd::stopped("已断开连接"),
                result = connect() => match result {
                    Ok(stream) => stream,
                    Err(error) => return ViewerEnd::from(error),
                }
            };
            session(stream, attempt).await
        };
        tokio::pin!(connection);
        let recovering = last_failure.is_some();
        let result = loop {
            tokio::select! {
                end = &mut connection => break Some(end),
                action = supervisor.control(recovering, Some((&progress, &commands))) => {
                    let stop = match action {
                        Action::Stop(end) => Some(end),
                        Action::AttentionChanged if supervisor.idle && recovering && progress.hello.get().is_none() => None,
                        _ => continue,
                    };
                    let _ = cancel.send(());
                    let _ = commands.send(ViewerCommand::Disconnect);
                    let end = connection.await;
                    if !end.retryable && !end.local_stop { return end; }
                    if let Some(stopped) = stop { return stopped; }
                    break None;
                }
            }
        };
        if let Some(end) = result {
            if !end.should_retry(supervisor.enabled) {
                return end;
            }
            backoff.finished(&progress);
            last_failure = Some(end);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DeskError;
    use std::future::{pending, ready};

    const QUALITY: StreamSettings = StreamSettings::new(1920, 30, 8);

    async fn completes<T>(future: impl Future<Output = T>) -> T {
        tokio::time::timeout(Duration::from_secs(5), future).await.expect("recovery did not respond to the control")
    }

    #[test]
    fn rapid_disconnects_keep_their_backoff_until_a_session_was_stable() {
        let mut backoff = RetryBackoff::default();
        let start = Instant::now();
        for expected in [1, 2, 4, 8, 16, 30, 30] {
            assert_eq!(backoff.next().as_secs(), expected);
            let progress = AttemptProgress { hello: start.into(), end: (start + Duration::from_secs(29)).into() };
            backoff.finished(&progress);
        }
        let stable = AttemptProgress { hello: start.into(), end: (start + Duration::from_secs(30)).into() };
        backoff.finished(&stable);
        assert_eq!(backoff.next().as_secs(), 1);
        assert_eq!(backoff.attempt, 1);
    }

    #[test]
    fn recovery_requires_a_retryable_failure_and_an_enabled_viewer() {
        let mut end = ViewerEnd::from(DeskError::Network("断线".into()));
        assert!(end.should_retry(true));
        assert!(!end.should_retry(false));
        end.host_ended = true;
        assert!(!end.should_retry(true));
        assert!(!ViewerEnd::from(DeskError::Pairing("验证失败".into())).should_retry(true));
    }

    #[tokio::test]
    async fn retry_now_interrupts_the_countdown() {
        let (input, controls) = mpsc::unbounded_channel();
        let mut supervisor = Supervisor { controls, quality: QUALITY, enabled: true, idle: false };
        input.send(ViewerControl::RetryNow).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        completes(supervisor.wait(deadline, 6, "断线", &mut |_| {})).await.unwrap();
    }

    #[tokio::test]
    async fn the_next_connection_keeps_the_selected_quality_and_discards_commands_from_an_older_session() {
        let desired = StreamSettings::new(1280, 30, 4);
        let (input, queue) = mpsc::unbounded_channel();
        let mut connections = 0;
        let mut stale = Some(ViewerControl::from(ViewerCommand::RequestClipboard));
        let end = completes(run(
            QUALITY,
            true,
            queue,
            |status| {
                if matches!(status, RetryStatus::Waiting { .. }) {
                    input.send(ViewerCommand::Quality(desired).into()).unwrap();
                    input.send(ViewerControl::RetryNow).unwrap();
                }
            },
            || {
                connections += 1;
                ready(if connections == 1 { Err(DeskError::Network("断线".into())) } else { Ok(()) })
            },
            |(), mut attempt| {
                let origin = &input;
                let stale = stale.take().unwrap();
                async move {
                    assert_eq!(attempt.quality, desired);
                    attempt.progress.hello.set(Instant::now()).unwrap();
                    origin.send(stale).unwrap();
                    origin.send(ViewerCommand::ReleaseInput.into()).unwrap();
                    assert!(matches!(attempt.commands.recv().await, Some(ViewerCommand::ReleaseInput)));
                    ViewerEnd::stopped("测试结束")
                }
            },
        ))
        .await;
        assert_eq!(end.reason, "测试结束");
        assert_eq!(connections, 2);
    }

    #[tokio::test]
    async fn an_idle_window_defers_recovery_and_can_cancel_without_opening_a_connection() {
        let (input, queue) = mpsc::unbounded_channel();
        let mut connections = 0;
        let mut deferred = false;
        let end = completes(run(
            QUALITY,
            true,
            queue,
            |status| match status {
                RetryStatus::Waiting { .. } => input.send(ViewerControl::Idle(true)).unwrap(),
                RetryStatus::Deferred { reason } => {
                    deferred = true;
                    assert_eq!(reason, "断线");
                    input.send(ViewerCommand::Disconnect.into()).unwrap();
                }
                RetryStatus::Connecting { .. } => panic!("idle viewer tried to reconnect"),
            },
            || {
                connections += 1;
                ready(Err::<(), _>(DeskError::Network("断线".into())))
            },
            |_, _| pending(),
        ))
        .await;
        assert!(deferred);
        assert_eq!(connections, 1);
        assert!(!end.retryable);
        assert!(end.local_stop);
    }

    #[tokio::test]
    async fn returning_to_an_idle_window_retries_and_disabling_recovery_interrupts_its_handshake() {
        let (input, queue) = mpsc::unbounded_channel();
        let mut connections = 0;
        let end = completes(run(
            QUALITY,
            true,
            queue,
            |status| match status {
                RetryStatus::Waiting { .. } => input.send(ViewerControl::Idle(true)).unwrap(),
                RetryStatus::Deferred { .. } => input.send(ViewerControl::Idle(false)).unwrap(),
                RetryStatus::Connecting { attempt } => assert_eq!(attempt, 1),
            },
            || {
                connections += 1;
                let first = connections == 1;
                let origin = &input;
                async move {
                    if first {
                        return Err::<(), _>(DeskError::Network("断线".into()));
                    }
                    origin.send(ViewerControl::AutoReconnect(false)).unwrap();
                    pending().await
                }
            },
            |_, _| pending(),
        ))
        .await;
        assert_eq!(connections, 2);
        assert_eq!(end.reason, "已关闭自动重连");
        assert!(!end.retryable);
        assert!(end.local_stop);
    }
}
