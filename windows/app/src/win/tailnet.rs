//! The privately embedded Tailscale process and its per-attempt loopback bridges.
use super::util::wide;
use quietdesk_core::PairingKey;
use quietdesk_core::error::{DeskError, Result as DeskResult};
use quietdesk_core::tls::{self, SecureStream};
use serde::Deserialize;
use serde_json::json;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Ipv4Addr;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use uuid::Uuid;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{PCWSTR, w};

type Answer<T> = std::result::Result<T, String>;
type Reply<T> = oneshot::Sender<Answer<T>>;

#[derive(Default, Deserialize)]
pub(super) struct Status {
    id: u64,
    pub state: Option<String>,
    pub ip: Option<Ipv4Addr>,
    #[serde(rename = "authURL")]
    pub auth_url: Option<String>,
    #[serde(rename = "peerPath")]
    pub peer_path: Option<String>,
    #[serde(rename = "peerRelay")]
    pub peer_relay: Option<String>,
    port: Option<u16>,
    #[serde(default)]
    udp: bool,
    error: Option<String>,
}

impl Status {
    fn append_peer_path(&self, text: &mut String) {
        match self.peer_path.as_deref() {
            Some("direct") => text.push_str(" · P2P 打洞直连"),
            Some("derp") => {
                let relay = self
                    .peer_relay
                    .as_deref()
                    .filter(|region| !region.is_empty() && region.len() <= 32 && region.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
                if let Some(relay) = relay {
                    text.push_str(&format!(" · DERP 中继 ({relay})"));
                } else {
                    text.push_str(" · DERP 中继转发");
                }
            }
            _ => {}
        }
    }
}

struct Executable(PathBuf);
impl Drop for Executable {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

struct Process {
    child: Child,
    input: Option<ChildStdin>,
    output: mpsc::Receiver<Status>,
    sequence: u64,
    _executable: Executable,
}

impl Process {
    fn start() -> io::Result<Self> {
        let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).filter(|p| p.is_absolute()).ok_or_else(|| io::Error::other("缺少本地用户目录"))?;
        Self::start_in(&local.join("QuietDesk"))
    }

    fn start_in(root: &Path) -> io::Result<Self> {
        fs::create_dir_all(root)?;
        let path = root.join(format!("QuietDeskTailnet-{}.exe", Uuid::new_v4()));
        let mut image = File::create_new(&path)?;
        let executable = Executable(path);
        image.write_all(include_bytes!(concat!(env!("OUT_DIR"), "/QuietDeskTailnet.exe")))?;
        drop(image);
        let mut child = Command::new(&executable.0)
            .arg("--state-dir")
            .arg(root.join("Tailscale"))
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let input = child.stdin.take().expect("stdin is piped");
        let mut output = BufReader::new(child.stdout.take().expect("stdout is piped"));
        let (send, receive) = mpsc::channel();
        let reader = thread::Builder::new().name("tailnet-response".into()).spawn(move || {
            loop {
                let mut line = Vec::new();
                if (&mut output).take(16_385).read_until(b'\n', &mut line).is_err() || line.last() != Some(&b'\n') {
                    break;
                }
                let Ok(response) = serde_json::from_slice(&line) else { break };
                if send.send(response).is_err() {
                    break;
                }
            }
        });
        if let Err(error) = reader {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        Ok(Self { child, input: Some(input), output: receive, sequence: 0, _executable: executable })
    }

    fn call(&mut self, op: &str, port: u16, host: Option<Ipv4Addr>, udp: bool) -> io::Result<Status> {
        self.sequence += 1;
        let mut request = json!({"id": self.sequence, "op": op});
        if matches!(op, "open" | "share" | "close") {
            request["port"] = json!(port);
        }
        if op == "share" {
            request["udp"] = json!(udp);
        }
        if let Some(host) = host {
            request["host"] = json!(host);
        }
        writeln!(self.input.as_mut().expect("stdin remains open until shutdown"), "{request}")?;
        let response = self.output.recv_timeout(Duration::from_secs(20)).map_err(|_| io::Error::other("内置 Tailscale 进程没有响应"))?;
        if response.id != self.sequence {
            return Err(io::Error::other("内置 Tailscale 进程响应顺序错误"));
        }
        Ok(response)
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        self.input.take();
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while std::time::Instant::now() < deadline {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => thread::sleep(Duration::from_millis(20)),
                Err(_) => break,
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Default, Clone)]
struct SharedSockets {
    tcp: Option<Arc<TcpListener>>,
    udp: Option<Arc<std::net::UdpSocket>>,
}

impl SharedSockets {
    fn ports(&self) -> (u16, bool) {
        let port = self.tcp.as_ref().and_then(|listener| listener.local_addr().ok()).map_or(0, |a| a.port());
        let udp = self.udp.as_ref().and_then(|s| s.local_addr().ok()).is_some_and(|a| a.port() == port);
        (port, udp)
    }
}

enum Request {
    Status { login: bool, reply: Reply<Status> },
    Logout(Reply<Status>),
    Share(SharedSockets),
    Open { ip: Ipv4Addr, port: u16, client: Client, reply: Reply<Bridge> },
    Close { port: u16, generation: u64 },
    Shutdown,
}

#[derive(Clone)]
pub(super) struct Client(mpsc::Sender<Request>);

/// The UI owns the process lifetime even when a viewer is retrying.
pub(super) struct Owner {
    pub client: Client,
    worker: Option<thread::JoinHandle<()>>,
}

impl Owner {
    pub fn start() -> Answer<Self> {
        let (send, receive) = mpsc::channel();
        let worker = thread::Builder::new().name("tailnet".into()).spawn(move || Worker::default().run(receive)).map_err(|e| e.to_string())?;
        Ok(Self { client: Client(send), worker: Some(worker) })
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.client.0.send(Request::Shutdown);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Client {
    pub fn status(&self, login: bool) -> oneshot::Receiver<Answer<Status>> {
        let (reply, receive) = oneshot::channel();
        let _ = self.0.send(Request::Status { login, reply });
        receive
    }

    pub fn logout(&self) -> oneshot::Receiver<Answer<Status>> {
        let (reply, receive) = oneshot::channel();
        let _ = self.0.send(Request::Logout(reply));
        receive
    }

    fn share(&self, sockets: SharedSockets) {
        let _ = self.0.send(Request::Share(sockets));
    }

    async fn bridge(&self, ip: Ipv4Addr, port: u16) -> DeskResult<Bridge> {
        let (reply, receive) = oneshot::channel();
        let _ = self.0.send(Request::Open { ip, port, client: self.clone(), reply });
        receive.await.map_err(|_| DeskError::invalid("内置 Tailscale 已关闭"))?.map_err(DeskError::platform)
    }
}

#[derive(Default)]
struct Worker {
    helper: Option<Process>,
    generation: u64,
    desired: SharedSockets,
    exposed: (u16, bool),
}

impl Worker {
    fn exchange(&mut self, op: &str, port: u16, ip: Option<Ipv4Addr>, udp: bool) -> Answer<Status> {
        if self.helper.is_none() {
            self.helper = Some(Process::start().map_err(|e| format!("无法启动内置 Tailscale：{e}"))?);
            self.generation += 1;
            self.exposed = (0, false);
        }
        self.helper.as_mut().unwrap().call(op, port, ip, udp).map_err(|error| {
            self.helper = None;
            self.exposed = (0, false);
            format!("Tailscale 通信中断：{error}")
        })
    }

    fn call(&mut self, op: &str, port: u16, ip: Option<Ipv4Addr>) -> Answer<Status> {
        let mut status = self.exchange(op, port, ip, false)?;
        if let Some(error) = status.error.take() {
            return Err(error);
        }
        Ok(status)
    }

    fn apply_share(&mut self) -> Answer<()> {
        let (port, udp) = self.desired.ports();
        if (port, udp) == self.exposed {
            return Ok(());
        }
        let status = self.exchange("share", port, None, udp)?;
        self.exposed = (status.port.unwrap_or(0), status.udp);
        // A failed UDP upgrade can leave the existing TCP service healthy.
        if (self.exposed.0 != 0 && self.exposed.0 != port) || (self.exposed.1 && !udp) {
            self.helper = None;
            self.exposed = (0, false);
            return Err("已关闭未能撤销共享的 Tailscale 进程".into());
        }
        status.error.map_or(Ok(()), Err)
    }

    fn run(mut self, receive: mpsc::Receiver<Request>) {
        for request in receive {
            match request {
                Request::Status { login, reply } => {
                    let answer = self.call(if login { "login" } else { "status" }, 0, None).and_then(|mut status| {
                        self.exposed = (status.port.unwrap_or(0), status.udp);
                        if status.state.as_deref() == Some("Running") {
                            if let Err(error) = self.apply_share() {
                                if self.helper.is_none() {
                                    return Err(error);
                                }
                                status.error = Some(error);
                            }
                            status.port = Some(self.exposed.0);
                            status.udp = self.exposed.1;
                        }
                        Ok(status)
                    });
                    let _ = reply.send(answer);
                }
                Request::Share(listener) => {
                    // Reserve the old loopback target until forwarding stops or the helper exits.
                    let old_listener = std::mem::replace(&mut self.desired, listener);
                    if self.helper.is_some() {
                        let _ = self.apply_share();
                    }
                    drop(old_listener);
                }
                Request::Logout(reply) => {
                    let result = self.call("logout", 0, None);
                    self.generation += 1;
                    self.exposed = (0, false);
                    if result.is_err() {
                        self.helper = None;
                    }
                    let _ = reply.send(result);
                }
                Request::Open { ip, port, client, reply } => {
                    if reply.is_closed() {
                        continue;
                    }
                    let result = self.call("open", port, Some(ip)).and_then(|s| {
                        let port = s.port.filter(|p| *p > 0).ok_or("Tailscale 未返回本地连接端口")?;
                        Ok(Bridge { client, port, generation: self.generation })
                    });
                    let _ = reply.send(result);
                }
                Request::Close { port, generation } => {
                    if self.helper.is_some() && generation == self.generation {
                        let _ = self.call("close", port, None);
                    }
                }
                Request::Shutdown => break,
            }
        }
    }
}

pub struct Bridge {
    client: Client,
    port: u16,
    generation: u64,
}
impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.client.0.send(Request::Close { port: self.port, generation: self.generation });
    }
}

/// Preserve the entered host for history and allocate forwarding sockets for each TLS attempt.
pub struct ViewerTarget(Endpoint);

enum Endpoint {
    Direct(String, u16),
    Embedded { address: Ipv4Addr, port: u16, client: Client },
}

impl From<(String, u16)> for ViewerTarget {
    fn from((address, port): (String, u16)) -> Self {
        Self(Endpoint::Direct(address, port))
    }
}

impl ViewerTarget {
    pub(super) fn embedded_host(address: &str) -> Option<&str> {
        let (prefix, host) = address.split_once(':')?;
        prefix.eq_ignore_ascii_case("tailscale").then_some(host)
    }
    pub(super) fn parse(address: &str, port: u16, client: Option<&Client>) -> DeskResult<Self> {
        let Some(host) = Self::embedded_host(address) else {
            return Ok(Self(Endpoint::Direct(address.to_owned(), port)));
        };
        let ip = host
            .parse::<Ipv4Addr>()
            .ok()
            .filter(|address| matches!(address.octets(), [100, 64..=127, _, _]))
            .ok_or_else(|| DeskError::invalid("请输入 tailscale: 加上对方的 Tailscale IPv4 地址"))?;
        let client = client.ok_or_else(|| DeskError::invalid("请先在“网络与线路 → Tailscale”登录"))?;
        Ok(Self(Endpoint::Embedded { address: ip, port, client: client.clone() }))
    }
    pub(super) fn address_label(&self) -> String {
        match &self.0 {
            Endpoint::Direct(host, _) => host.clone(),
            Endpoint::Embedded { address, .. } => format!("tailscale:{address}"),
        }
    }
    pub(super) async fn connect(&self, key: &PairingKey) -> DeskResult<(SecureStream, Option<Bridge>)> {
        match &self.0 {
            Endpoint::Direct(host, port) => Ok((tls::connect(host, *port, key).await?, None)),
            Endpoint::Embedded { address, port, client } => {
                let bridge = client.bridge(*address, *port).await?;
                Ok((tls::connect("127.0.0.1", bridge.port, key).await?, Some(bridge)))
            }
        }
    }
}

fn official_auth_url(url: &str) -> bool {
    quietdesk_core::update::parse_http_url(url)
        .is_ok_and(|u| u.scheme == "https" && u.host == "login.tailscale.com" && u.effective_port() == 443 && u.path != "/")
}

pub(super) fn open_auth(url: &str) -> Answer<()> {
    if !official_auth_url(url) {
        return Err("Tailscale 返回了无效的官方登录地址".into());
    }
    let result = unsafe { ShellExecuteW(None, w!("open"), PCWSTR(wide(url).as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    if (result.0 as isize) <= 32 {
        return Err("无法打开浏览器登录 Tailscale".into());
    }
    Ok(())
}

enum Action {
    Poll,
    Login,
    Logout,
}

pub(super) struct Panel {
    owner: Option<Owner>,
    pending: Option<(Action, oneshot::Receiver<Answer<Status>>)>,
    login_deadline: Option<std::time::Instant>,
    next_poll: std::time::Instant,
    shared: SharedSockets,
    running: bool,
    address: String,
    text: String,
}

impl Default for Panel {
    fn default() -> Self {
        Self {
            owner: None,
            pending: None,
            login_deadline: None,
            next_poll: std::time::Instant::now(),
            shared: SharedSockets::default(),
            running: false,
            address: String::new(),
            text: "未启用".into(),
        }
    }
}

impl Panel {
    pub fn enable(&mut self, login: bool) -> bool {
        if self.owner.is_none() {
            let owner = match Owner::start() {
                Ok(owner) => owner,
                Err(error) => {
                    self.text = format!("启动失败：{error}");
                    return false;
                }
            };
            owner.client.share(self.shared.clone());
            self.owner = Some(owner);
        }
        let client = self.client().unwrap();
        self.pending = Some((if login { Action::Login } else { Action::Poll }, client.status(login)));
        self.login_deadline = login.then(|| std::time::Instant::now() + Duration::from_secs(90));
        self.text = if login { "正在请求网页登录…" } else { "正在读取节点状态…" }.into();
        true
    }

    pub fn logout(&mut self) {
        if let Some(client) = self.client() {
            self.pending = Some((Action::Logout, client.logout()));
            self.login_deadline = None;
            self.text = "正在退出 Tailscale…".into();
        }
    }

    pub fn share(&mut self, listener: Option<Arc<TcpListener>>) {
        self.shared = SharedSockets { tcp: listener, udp: None };
        if let Some(client) = self.client() {
            client.share(self.shared.clone());
        }
    }

    pub fn media_socket(&mut self, active: bool, socket: Arc<std::net::UdpSocket>) {
        if active {
            self.shared.udp = Some(socket);
        } else if self.shared.udp.as_ref().is_some_and(|old| Arc::ptr_eq(old, &socket)) {
            self.shared.udp = None;
        } else {
            return;
        }
        if let Some(client) = self.client() {
            client.share(self.shared.clone());
        }
    }

    pub fn client(&self) -> Option<&Client> {
        self.owner.as_ref().map(|o| &o.client)
    }
    pub fn address(&self) -> &str {
        &self.address
    }
    pub fn status_line(&self) -> &str {
        &self.text
    }
    pub fn can_login(&self) -> bool {
        !self.running && !matches!(self.pending, Some((Action::Login | Action::Logout, _)))
    }
    pub fn can_logout(&self) -> bool {
        self.owner.is_some() && !matches!(self.pending, Some((Action::Logout, _)))
    }

    /// Returns true after the helper confirms logout, when the persisted setting can be cleared.
    pub fn tick(&mut self) -> bool {
        let now = std::time::Instant::now();
        if let Some((action, mut pending)) = self.pending.take() {
            let result = match pending.try_recv() {
                Ok(result) => result,
                Err(oneshot::error::TryRecvError::Empty) => {
                    self.pending = Some((action, pending));
                    return false;
                }
                Err(oneshot::error::TryRecvError::Closed) => Err("内置 Tailscale 已停止".into()),
            };
            match result {
                Ok(_) if matches!(action, Action::Logout) => {
                    self.owner = None;
                    self.running = false;
                    self.address.clear();
                    self.text = "已退出 Tailscale".into();
                    return true;
                }
                Ok(status) => {
                    self.running = status.state.as_deref() == Some("Running");
                    self.address = status.ip.filter(|_| self.running).map(|ip| format!("tailscale:{ip}")).unwrap_or_default();
                    self.text = match status.state.as_deref() {
                        Some("Running") if self.address.is_empty() => "已加入网络，等待 IPv4 地址".into(),
                        Some("Running") => status.port.filter(|p| *p != 0).map_or_else(
                            || "已加入网络 · 本机未通过 Tailscale 共享".into(),
                            |p| format!("已加入网络 · 本机共享端口 {p}（{}）", if status.udp { "TCP / UDP" } else { "TCP" }),
                        ),
                        Some("NeedsLogin") => "等待登录 Tailscale".into(),
                        Some("NeedsMachineAuth") => "等待 tailnet 管理员批准此设备".into(),
                        Some("Starting") => "正在连接 Tailscale…".into(),
                        Some("Stopped") => "节点已停止".into(),
                        _ => "等待节点就绪".into(),
                    };
                    if self.running {
                        status.append_peer_path(&mut self.text);
                    }
                    if let Some(error) = status.error {
                        self.text.push_str(&format!(" · {error}"));
                    }
                    if self.running || self.login_deadline.is_some_and(|t| t <= now) {
                        self.login_deadline = None;
                    }
                    if self.login_deadline.is_some()
                        && let Some(url) = status.auth_url.filter(|s| !s.is_empty())
                    {
                        self.login_deadline = None;
                        self.text = open_auth(&url).map_or_else(|e| e, |_| "请在浏览器完成登录".into());
                    }
                }
                Err(error) => {
                    self.address.clear();
                    self.text = format!("Tailscale：{error}");
                    self.running = false;
                }
            }
            self.next_poll = now + Duration::from_secs(if self.login_deadline.is_some() { 1 } else { 4 });
        } else if now >= self.next_poll
            && let Some(client) = self.client()
        {
            self.pending = Some((Action::Poll, client.status(false)));
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_helper_answers_over_stdio_and_cleans_up_without_enrollment() {
        let root = std::env::temp_dir().join(format!("quietdesk-tailnet-check-{}", Uuid::new_v4()));
        let mut process = Process::start_in(&root).unwrap();
        let image = process._executable.0.clone();
        // An invalid request is rejected before starting the node or contacting a control server.
        writeln!(process.input.as_mut().unwrap(), "{{\"id\":0}}").unwrap();
        let response = process.output.recv_timeout(Duration::from_secs(15)).unwrap();
        assert_eq!(response.id, 0);
        assert!(response.error.is_some());
        drop(process);
        assert!(!image.exists());
        assert!(!root.join("Tailscale").exists());
        fs::remove_dir(&root).unwrap();
    }

    #[tokio::test]
    async fn failed_pairing_closes_only_its_per_attempt_bridge() {
        use tokio::net::TcpListener;
        let (send, recv) = mpsc::channel();
        let client = Client(send);
        let direct = ViewerTarget::parse("100.68.2.3", 5908, None).unwrap();
        assert!(matches!(direct.0, Endpoint::Direct(..)));
        let target = ViewerTarget::parse("Tailscale:100.68.2.3", 5908, Some(&client)).unwrap();
        let local = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let local_port = local.local_addr().unwrap().port();
        let worker = thread::spawn(move || {
            let Request::Open { ip, port, client, reply } = recv.recv_timeout(Duration::from_secs(4)).unwrap() else { panic!("expected bridge request") };
            assert_eq!((ip.octets(), port), ([100, 68, 2, 3], 5908));
            assert!(reply.send(Ok(Bridge { client, port: local_port, generation: 1 })).is_ok());
            assert!(matches!(recv.recv_timeout(Duration::from_secs(8)).unwrap(), Request::Close { port, generation: 1 } if port == local_port));
        });
        let key = PairingKey::from_bytes([42; 32]);
        let (attempt, ()) = tokio::join!(target.connect(&key), async {
            drop(local.accept().await.unwrap());
        });
        assert!(attempt.is_err());
        worker.join().unwrap();
    }

    #[test]
    fn only_official_web_auth_can_launch_the_browser() {
        assert!(official_auth_url("https://login.tailscale.com/a/example"));
        assert!(!official_auth_url("https://login.tailscale.com.evil.example/a/test"));
        assert!(!official_auth_url("file:///C:/test"));
    }
}
