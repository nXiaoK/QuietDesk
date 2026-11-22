use super::*;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::fs;

struct Pair {
    states: [State; 2],
    wire: Vec<(usize, Message)>,
    actions: VecDeque<(usize, Action)>,
    root: PathBuf,
}
impl Pair {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("quietdesk-clipboard-test-{}", Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let mut p = Self {
            states: [
                State::new(Role::Viewer, root.join("a"), true, true, Arc::new(storage::PortableStorage)),
                State::new(Role::Host, root.join("b"), true, true, Arc::new(storage::PortableStorage)),
            ],
            root,
            wire: vec![],
            actions: VecDeque::new(),
        };
        p.states[0].greet();
        p.exchange(0);
        p
    }
    fn exchange(&mut self, idx: usize) {
        let mut queue = VecDeque::from([(idx, std::mem::take(&mut self.states[idx].effects))]);
        while let Some((i, effects)) = queue.pop_front() {
            for item in effects {
                match item {
                    Output::Send(m) => {
                        self.wire.push((i, m.clone()));
                        self.states[1 - i].handle(Input::Peer(m));
                        queue.push_back((1 - i, std::mem::take(&mut self.states[1 - i].effects)))
                    }
                    Output::Native(a) => self.actions.push_back((i, a)),
                    Output::ProtocolError(reason) => panic!("peer protocol error: {reason}"),
                }
            }
        }
    }
    fn act(&mut self, i: usize, input: Input) {
        self.states[i].handle(input);
        self.exchange(i);
    }
    fn readies(&mut self, kind: Kind) -> Revision {
        self.act(0, Input::LocalChanged { token: 57, kind: Some(kind) });
        let manifest = self.wire.last().unwrap().1.read_json::<Manifest>().unwrap();
        assert!(matches!(self.actions.back(),Some((1,Action::Advertise {revision,kind:k})) if *revision==manifest.revision && *k==kind));
        self.act(1, Input::Paste(manifest.revision));
        assert!(matches!(self.actions.back(),Some((0,Action::Read{token:57,kind:k})) if *k==kind));
        manifest.revision
    }
}
impl Drop for Pair {
    fn drop(&mut self) {
        self.states[0].cancel("结束", false);
        self.states[1].cancel("结束", false);
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn raw(kind: M, fields: Value) -> Input {
    Input::Peer(Message::json(kind, &fields).unwrap())
}
fn legacy(state: &mut State) {
    state.handle(raw(M::ClipboardSettings, json!({"session":state.session.unwrap_or_else(Uuid::new_v4),"enabled":true,"fileApproval":true})));
    state.effects.clear()
}
#[test]
fn text_pull_binds_manifest_to_a_new_transfer_and_acks_only_after_native_apply() {
    let mut p = Pair::new();
    assert_eq!(p.wire.iter().map(|(i, m)| (*i, m.kind)).collect::<Vec<_>>(), [(0, M::ClipboardSettings), (1, M::ClipboardSettings)]);
    let pref: Value = p.wire[0].1.read_json().unwrap();
    assert_eq!(pref["physicalFilePasteV1"], true);
    assert_eq!(pref["chunkWindow"], false);
    let manifest = p.readies(Kind::Text);
    p.act(1, Input::Paste(manifest));
    assert_eq!(p.wire.iter().filter(|(_, m)| m.kind == M::ClipboardPull).count(), 1);
    let value = "Q中".repeat(9000);
    p.act(0, Input::Read { token: 57, payload: Some(Payload::Text(value.clone())) });
    let begin: Begin = p.wire.iter().find(|(_, m)| m.kind == M::ClipboardBegin).unwrap().1.read_json().unwrap();
    assert_eq!(begin.revision.origin, manifest.origin);
    assert!(begin.revision.counter > manifest.counter);
    let chunk = &p.wire.iter().find(|(_, m)| m.kind == M::ClipboardChunk).unwrap().1.payload;
    assert_eq!(&chunk[..8], &begin.revision.counter.to_be_bytes());
    assert_eq!(&chunk[8..24], begin.revision.origin.as_bytes());
    assert_eq!(&chunk[24..32], &2u64.to_be_bytes());
    assert_eq!(chunk.len(), 32 + CHUNK);
    assert!(
        matches!(p.actions.back(),Some((1,Action::Apply{revision,manifest:Some(parent),payload:Payload::Text(text),..})) if *revision==begin.revision && *parent==manifest && text==&value)
    );
    assert_eq!(p.wire.last().unwrap().1.kind, M::ClipboardEnd);
    p.act(1, Input::Applied { revision: begin.revision, success: true });
    assert!(p.states[0].outgoing.is_none());
}
#[cfg(unix)]
#[test]
fn file_paste_waits_for_approval_before_streaming_and_publishes_only_verified_tree() {
    let mut p = Pair::new();
    let tree = p.root.join("Demo");
    fs::create_dir(&tree).unwrap();
    fs::write(tree.join("test"), b"private fixture").unwrap();
    let timestamp = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000);
    fs::File::open(tree.join("test")).unwrap().set_modified(timestamp).unwrap();
    let manifest = p.readies(Kind::Files);
    p.act(0, Input::Read { token: 57, payload: Some(Payload::Files(vec![tree])) });
    let Some((1, Action::FileOffer(offer))) = p.actions.back() else { panic!("missing offer") };
    let rev = offer.revision;
    assert_eq!(offer.names, ["Demo"]);
    assert_eq!((offer.roots, offer.entries, offer.bytes), (1, 2, 15));
    assert_eq!(p.wire.last().unwrap().1.kind, M::ClipboardBegin);
    assert!(!p.states[1].storage.exists());
    p.act(1, Input::Decision { revision: rev, accept: true });
    let Some((1, Action::Apply { manifest: Some(source), payload: Payload::Files(paths), .. })) = p.actions.back() else { panic!("not applied") };
    assert_eq!(*source, manifest);
    assert!(paths[0].starts_with(p.states[1].storage.join("received").canonicalize().unwrap()));
    assert_eq!(fs::read(paths[0].join("test")).unwrap(), b"private fixture");
    assert_eq!(fs::metadata(paths[0].join("test")).unwrap().modified().unwrap(), timestamp);
    assert_eq!(fs::read_dir(p.states[1].storage.join("partial")).unwrap().count(), 0);
    p.act(1, Input::Applied { revision: rev, success: true });
    assert!(p.states[0].outgoing.is_none());
}
#[cfg(unix)]
#[test]
fn declining_an_offer_never_creates_a_staging_directory_or_authorizes_bytes() {
    let mut p = Pair::new();
    let path = p.root.join("test");
    fs::write(&path, b"not sent").unwrap();
    p.readies(Kind::Files);
    p.act(0, Input::Read { token: 57, payload: Some(Payload::Files(vec![path])) });
    let rev = p.states[1].incoming.as_ref().unwrap().begin.revision;
    p.act(1, Input::Decision { revision: rev, accept: false });
    assert_eq!(p.wire.last().unwrap().1.kind, M::ClipboardCancel);
    assert!(p.states[0].outgoing.is_none());
    assert!(!p.wire.iter().any(|(_, m)| m.kind == M::ClipboardEntry));
    assert!(!p.states[1].storage.exists());
}
#[cfg(unix)]
#[test]
fn unsafe_entry_or_early_payload_cancels_the_transfer_and_removes_partials() {
    for bad_path in ["../outside", "C:/windows", "a\\b", "a:stream", "CON.txt", "a."] {
        let mut p = Pair::new();
        let state = &mut p.states[1];
        legacy(state);
        let rev = Revision { counter: 1, origin: Uuid::new_v4() };
        state.handle(raw(M::ClipboardBegin, json!({"revision":rev,"sequence":0,"type":"files","bytes":4,"count":1})));
        state.handle(Input::Decision { revision: rev, accept: true });
        state.handle(raw(M::ClipboardEntry, json!({"revision":rev,"sequence":1,"path":bad_path,"bytes":4,"mode":384,"modified":0,"directory":false})));
        assert!(state.incoming.is_none());
        assert!(state.effects.iter().any(|e| matches!(e,Output::Send(m) if m.kind==M::ClipboardCancel)));
        assert_eq!(fs::read_dir(state.storage.join("partial")).unwrap().count(), 0);
    }
    let mut p = Pair::new();
    let state = &mut p.states[1];
    legacy(state);
    let rev = Revision { counter: 1, origin: Uuid::new_v4() };
    state.handle(raw(M::ClipboardBegin, json!({"revision":rev,"sequence":0,"type":"files","bytes":1,"count":1})));
    state.handle(raw(M::ClipboardEntry, json!({"revision":rev,"sequence":1,"path":"safe","bytes":1,"mode":384,"modified":0,"directory":false})));
    assert!(state.incoming.is_none());
    assert!(!state.storage.exists());
}
#[cfg(unix)]
#[test]
fn source_links_and_duplicate_case_names_never_open_a_file_offer() {
    let p = Pair::new();
    let tree = p.root.join("root");
    fs::create_dir(&tree).unwrap();
    fs::write(p.root.join("elsewhere"), b"private").unwrap();
    std::os::unix::fs::symlink(p.root.join("elsewhere"), tree.join("link")).unwrap();
    assert!(storage::catalogue(vec![tree.clone()], &storage::PortableStorage).is_err());
    fs::remove_file(tree.join("link")).unwrap();
    assert!(storage::catalogue(vec![tree.clone(), tree], &storage::PortableStorage).is_err());
}
#[test]
fn focus_only_exposes_the_newest_copy_once_and_cancelled_reads_cannot_send_data() {
    let mut p = Pair::new();
    p.act(1, Input::Preferences { enabled: true, receives: false });
    for token in 1..=3 {
        p.act(0, Input::LocalChanged { token, kind: Some(Kind::Text) });
    }
    assert!(!p.wire.iter().any(|(_, m)| m.kind == M::ClipboardManifest));
    p.act(1, Input::Preferences { enabled: true, receives: true });
    let revision = p.states[0].local_manifest.unwrap().revision;
    p.act(1, Input::Preferences { enabled: true, receives: false });
    p.act(1, Input::Preferences { enabled: true, receives: true });
    assert_eq!(p.wire.iter().filter(|(_, m)| m.kind == M::ClipboardManifest).count(), 1);
    p.act(1, Input::Paste(revision));
    p.act(0, Input::LocalChanged { token: 4, kind: None });
    p.act(0, Input::Read { token: 3, payload: Some(Payload::Text("stale".into())) });
    assert!(!p.wire.iter().any(|(_, m)| m.kind == M::ClipboardBegin));
    assert!(p.states[1].pull.is_none());
    assert!(p.states[1].remote_manifest.is_none());
}
#[test]
fn legacy_eager_text_omits_extensions_and_reordered_chunks_fail_without_application() {
    let mut p = Pair::new();
    for s in &mut p.states {
        legacy(s)
    }
    p.act(0, Input::LocalChanged { token: 6, kind: Some(Kind::Text) });
    p.act(0, Input::Read { token: 6, payload: Some(Payload::Text("old peer".into())) });
    let (_, m) = p.wire.iter().find(|(_, m)| m.kind == M::ClipboardBegin).unwrap();
    let b: Value = m.read_json().unwrap();
    assert!(b.get("chunkWindow").is_none() && b.get("pullRequestID").is_none());
    assert!(matches!(p.actions.back(),Some((1,Action::Apply{manifest:None,payload:Payload::Text(s),..})) if s=="old peer"));
    let rev = Revision { counter: 51, origin: Uuid::new_v4() };
    p.states[1].handle(raw(M::ClipboardBegin, json!({"revision":rev,"sequence":0,"count":1,"type":"text","bytes":1})));
    p.states[1].handle(raw(M::ClipboardEnd, json!({"revision":rev,"sequence":3})));
    assert!(p.states[1].incoming.is_none());
    assert!(p.states[1].effects.iter().any(|e| matches!(e,Output::Send(m) if m.kind==M::ClipboardCancel)));
}

#[test]
fn an_eager_png_decodes_before_native_application_and_oversized_text_never_gets_credit() {
    let mut p = Pair::new();
    for s in &mut p.states {
        legacy(s)
    }
    let mut data = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut data, 1, 1);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[0, 5, 15, 255]).unwrap();
    }
    p.act(0, Input::LocalChanged { token: 1, kind: Some(Kind::Png) });
    p.act(0, Input::Read { token: 1, payload: Some(Payload::Png(data.clone())) });
    assert!(matches!(p.actions.back(),Some((1,Action::Apply{manifest:None,payload:Payload::Png(bytes),..})) if bytes==&data));
    let s = &mut p.states[1];
    let rev = Revision { counter: 40, origin: Uuid::new_v4() };
    s.effects.clear();
    s.handle(raw(M::ClipboardBegin, json!({"revision":rev,"type":"text","count":1,"sequence":0,"bytes":MAX_TEXT_BYTES+1})));
    assert!(s.effects.iter().any(|e| matches!(e,Output::Send(m) if m.kind==M::ClipboardCancel)));
    assert!(!s.effects.iter().any(|e| matches!(e,Output::Send(m) if m.kind==M::ClipboardReceipt)));
    assert!(s.incoming.is_none());
}
#[cfg(unix)]
#[test]
fn a_source_replaced_while_awaiting_approval_cannot_be_substituted() {
    let mut p = Pair::new();
    let path = p.root.join("selection");
    fs::write(&path, b"a").unwrap();
    let timestamp = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_001);
    fs::File::open(&path).unwrap().set_modified(timestamp).unwrap();
    p.readies(Kind::Files);
    p.act(0, Input::Read { token: 57, payload: Some(Payload::Files(vec![path.clone()])) });
    fs::rename(&path, p.root.join("original")).unwrap();
    fs::write(&path, b"b").unwrap();
    fs::File::open(&path).unwrap().set_modified(timestamp).unwrap();
    let rev = p.states[1].incoming.as_ref().unwrap().begin.revision;
    p.act(1, Input::Decision { revision: rev, accept: true });
    assert!(p.wire.iter().any(|(i, m)| *i == 0 && m.kind == M::ClipboardCancel));
    assert!(!p.wire.iter().any(|(_, m)| m.kind == M::ClipboardChunk));
    assert!(!p.actions.iter().any(|(_, a)| matches!(a, Action::Apply { .. })));
}

#[cfg(unix)]
#[test]
fn abandoned_file_bytes_are_reclaimed_without_touching_active_transfers_or_unrelated_folders() {
    let p = Pair::new();
    let root = &p.states[0].storage;
    let live = storage::Staging::new(root, 0, &storage::PortableStorage).unwrap();
    let partial = root.join("partial");
    let crash = partial.join(Uuid::new_v4().hyphenated().to_string());
    fs::create_dir_all(crash.join("payload")).unwrap();
    fs::write(crash.join(".lease"), b"").unwrap();
    fs::write(crash.join("payload/incomplete"), b"incomplete").unwrap();
    let unrelated = partial.join("other");
    fs::create_dir(&unrelated).unwrap();
    let next = storage::Staging::new(root, 0, &storage::PortableStorage).unwrap();
    assert!(!crash.exists());
    assert!(unrelated.is_dir());
    assert_eq!(fs::read_dir(&partial).unwrap().count(), 3);
    drop((live, next));
    assert_eq!(fs::read_dir(partial).unwrap().count(), 1);
}

#[cfg(unix)]
#[test]
fn a_new_local_copy_during_an_approved_file_download_is_preserved_until_the_file_is_saved() {
    let mut p = Pair::new();
    let path = p.root.join("sample");
    let contents = vec![0x42; CHUNK + 47];
    fs::write(&path, &contents).unwrap();
    p.readies(Kind::Files);
    p.act(0, Input::Read { token: 57, payload: Some(Payload::Files(vec![path])) });
    let rev = p.states[1].incoming.as_ref().unwrap().begin.revision;
    p.states[1].handle(Input::Decision { revision: rev, accept: true });
    for (from, expected) in [(1, M::ClipboardReceipt), (0, M::ClipboardEntry), (1, M::ClipboardReceipt), (0, M::ClipboardChunk)] {
        let i = p.states[from].effects.iter().position(|e| matches!(e, Output::Send(_))).unwrap();
        let Output::Send(m) = p.states[from].effects.remove(i) else { unreachable!() };
        assert_eq!(m.kind, expected);
        p.states[1 - from].handle(Input::Peer(m));
    }
    let mac = &mut p.states[1];
    mac.handle(Input::LocalChanged { token: 100, kind: Some(Kind::Text) });
    mac.handle(Input::LocalChanged { token: 101, kind: Some(Kind::Png) });
    assert!(!mac.effects.iter().any(|e| matches!(e,Output::Send(m) if m.kind==M::ClipboardManifest||m.kind==M::ClipboardCancel)));
    p.exchange(1);
    let final_ack = p.wire.iter().position(|(i, m)| *i == 1 && m.kind == M::ClipboardReceipt && m.read_json::<Receipt>().unwrap().sequence == 4).unwrap();
    let new_manifest = p.wire.iter().position(|(i, m)| *i == 1 && m.kind == M::ClipboardManifest).unwrap();
    assert!(final_ack < new_manifest);
    assert_eq!(p.wire[new_manifest].1.read_json::<Manifest>().unwrap().kind, Kind::Png);
    assert_eq!(p.states[1].published_token, Some(101));
    assert!(p.actions.iter().any(|(_, a)| matches!(a,Action::Status(s) if s.contains("保留了新的本机复制"))));
    assert!(!p.actions.iter().any(|(i, a)| *i == 1 && matches!(a, Action::Apply { .. })));
    let completed = fs::read_dir(p.states[1].storage.join("received")).unwrap().next().unwrap().unwrap().path().join("sample");
    assert_eq!(fs::read(completed).unwrap(), contents);
}
#[test]
fn stale_or_unrequested_file_transfers_cannot_create_a_prompt_after_disable() {
    let mut p = Pair::new();
    let m = p.readies(Kind::Files);
    let request = p.states[1].pull.unwrap();
    let state = &mut p.states[1];
    let begin = |rev: Revision, request_id: Uuid| {
        raw(M::ClipboardBegin, json!({"revision":rev,"sequence":0,"type":"files","count":1,"bytes":1,"pullRequestID":request_id}))
    };
    state.handle(begin(Revision { counter: m.counter + 1, origin: Uuid::new_v4() }, request.request_id));
    assert!(state.incoming.is_none() && state.pull.is_none());
    state.handle(Input::Preferences { enabled: false, receives: false });
    state.effects.clear();
    state.handle(begin(Revision { counter: m.counter + 2, origin: m.origin }, request.request_id));
    assert!(state.incoming.is_none() && state.effects.is_empty());
}
