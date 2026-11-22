//! Runs the Windows platform code without its windows, for checks on Windows or under Wine:
//! `capture` grabs the screen, `codec` encodes captured or synthetic frames and decodes them again,
//! `host` shares this machine, `viewer` connects and decodes without drawing.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() {
    use quietdesk_core::host::{HostCommand, HostOptions};
    use quietdesk_core::keymap::MacModifierMapping;
    use quietdesk_core::media::MediaStreamId;
    use quietdesk_core::messages::StreamSettings;
    use quietdesk_core::pairing::PairingKey;
    use quietdesk_core::pixel::Nv12Converter;
    use quietdesk_core::viewer::ViewerEvent;
    use quietdesk_windows::win::app::{Frame, ViewerSink, network_runtime, run_viewer, serve_host};
    use quietdesk_windows::win::capture::ScreenCapture;
    use quietdesk_windows::win::codec::{H264Decoder, H264Encoder, MediaFoundation};
    use quietdesk_windows::win::util::Com;
    use std::sync::{Arc, Mutex};

    fn fail(step: &str, error: impl std::fmt::Display) -> ! {
        println!("FAIL {step}: {error}");
        std::process::exit(1)
    }

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| arguments.iter().position(|argument| argument == name).and_then(|index| arguments.get(index + 1)).cloned();
    // What the application writes to its log file goes to standard error here.
    let _logger = flexi_logger::Logger::try_with_str("info").and_then(|logger| logger.log_to_stderr().start());
    let _com = Com::enter();
    match arguments.first().map(String::as_str) {
        Some("capture") => {
            let mut capture = ScreenCapture::open().unwrap_or_else(|error| fail("open capture", error));
            let changed = capture.grab(500).unwrap_or_else(|error| fail("grab", error));
            let lit = capture.frame.chunks(4).filter(|pixel| pixel[..3] != [0, 0, 0]).count();
            if let Some(path) = option("--save") {
                // A 32-bit top-down BMP of what was captured, to look at.
                let (width, height) = (capture.width() as u32, capture.height() as u32);
                let mut file = Vec::with_capacity(54 + capture.frame.len());
                file.extend_from_slice(b"BM");
                file.extend_from_slice(&(54 + capture.frame.len() as u32).to_le_bytes());
                file.extend_from_slice(&[0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0]);
                file.extend_from_slice(&width.to_le_bytes());
                file.extend_from_slice(&(height as i32).wrapping_neg().to_le_bytes());
                file.extend_from_slice(&[1, 0, 32, 0]);
                file.extend_from_slice(&[0; 24]);
                file.extend_from_slice(&capture.frame);
                std::fs::write(&path, file).unwrap_or_else(|error| fail("save", error));
            }
            println!("PASS capture {}x{} changed={changed} non-black pixels={lit} pointer={}", capture.width(), capture.height(), capture.pointer().is_some());
        }
        Some("codec") => {
            let _media = MediaFoundation::start().unwrap_or_else(|error| fail("Media Foundation", error));
            let (width, height) = (640usize, 360usize);
            let settings = StreamSettings::new(1920, 30, 4);
            let mut encoder = H264Encoder::new(width as u32, height as u32, settings).unwrap_or_else(|error| fail("create encoder", error));
            let mut decoder = H264Decoder::new().unwrap_or_else(|error| fail("create decoder", error));
            let converter = Nv12Converter::new((width, height), (width, height));
            let mut nv12 = vec![0u8; converter.output_bytes()];
            // Windows' own encoder answers every frame at once; other implementations may hold frames back first.
            let frames = option("--frames").and_then(|frames| frames.parse().ok()).unwrap_or(30usize);
            let (mut encoded, mut keys, mut decoded, mut bytes) = (0, 0, 0, 0);
            let (mut first_output, mut first_is_key, mut key_after_request) = (None, false, false);
            let mut size = (0, 0);
            for frame in 0..frames {
                let bgra: Vec<u8> = (0..width * height).flat_map(|index| [((index % width + frame * 4) / 2) as u8, (index / width) as u8, 128, 255]).collect();
                converter.convert(&bgra, width * 4, &mut nv12);
                if frame == frames / 2 {
                    encoder.request_key_frame();
                }
                let Some(output) = encoder.encode(&nv12).unwrap_or_else(|error| fail("encode", error)) else { continue };
                if first_output.is_none() {
                    first_output = Some(frame);
                    first_is_key = output.is_key_frame();
                }
                encoded += 1;
                keys += usize::from(output.is_key_frame());
                key_after_request |= output.is_key_frame() && frame >= frames / 2;
                bytes += output.avcc.len();
                let packet = quietdesk_core::video::VideoPacket::h264(frame as u32, output);
                let stream = packet.annex_b().unwrap_or_else(|error| fail("annex b", error));
                decoder
                    .decode(&stream, |picture| {
                        decoded += 1;
                        size = (picture.width, picture.height);
                    })
                    .unwrap_or_else(|error| fail("decode", error));
            }
            println!(
                "codec frames={frames} encoded={encoded} first output at frame {first_output:?} keyframes={keys} bytes={bytes} decoded={decoded} size={}x{}",
                size.0, size.1
            );
            if first_is_key && key_after_request && decoded > 0 && size == (width, height) {
                println!("PASS codec");
            } else {
                fail("codec", "no keyframe at the start or after the request, or no decoded picture of the encoded size");
            }
        }
        Some("host") => {
            let key = PairingKey::parse(&option("--code").unwrap_or_default()).unwrap_or_else(|error| fail("pairing code", error));
            let port = option("--port").and_then(|port| port.parse().ok()).unwrap_or(5908);
            let limit = StreamSettings::new(2560, 60, 30);
            let options = HostOptions {
                name: "wincheck".to_string(),
                allow_control: true,
                clipboard: false,
                preferred: limit,
                limit,
                modifiers: MacModifierMapping::CommandAsControl,
            };
            let (_commands, queue) = tokio::sync::mpsc::unbounded_channel::<HostCommand>();
            network_runtime().spawn(serve_host(port, key, Arc::new(Mutex::new(options)), queue, |notice| println!("host {notice:?}")));
            std::thread::sleep(std::time::Duration::from_secs(option("--seconds").and_then(|seconds| seconds.parse().ok()).unwrap_or(3600)));
        }
        Some("viewer") => {
            #[derive(Default)]
            struct Counts {
                pictures: u64,
                committed: Option<MediaStreamId>,
                media_pictures: u64,
                showed_candidate: bool,
            }
            #[derive(Default)]
            struct Report(Mutex<Counts>);
            impl ViewerSink for Report {
                fn event(&self, event: ViewerEvent) {
                    if let ViewerEvent::MediaCommitted(stream) = event {
                        let mut counts = self.0.lock().unwrap();
                        counts.committed = Some(stream);
                        counts.media_pictures = 0;
                    }
                    if !matches!(event, ViewerEvent::RoundTrip(_)) {
                        println!("viewer {event:?}");
                    }
                }
                fn frame_ready(&self, stream: Option<MediaStreamId>) {
                    let mut counts = self.0.lock().unwrap();
                    counts.pictures += 1;
                    if stream.is_some() {
                        if stream == counts.committed {
                            counts.media_pictures += 1;
                        } else {
                            counts.showed_candidate = true;
                        }
                    }
                }
            }
            let key = PairingKey::parse(&option("--code").unwrap_or_default()).unwrap_or_else(|error| fail("pairing code", error));
            let (address, port) =
                (option("--host").unwrap_or_else(|| "127.0.0.1".to_string()), option("--port").and_then(|port| port.parse().ok()).unwrap_or(5908));
            let seconds = option("--seconds").and_then(|seconds| seconds.parse().ok()).unwrap_or(5);
            let (commands, queue) = tokio::sync::mpsc::unbounded_channel();
            let (frame, report) = (Arc::new(Mutex::new(Frame::default())), Arc::new(Report::default()));
            let session = network_runtime().spawn(run_viewer(address, port, key, StreamSettings::new(1920, 30, 8), queue, frame.clone(), report.clone()));
            std::thread::sleep(std::time::Duration::from_secs(seconds));
            let disconnected = commands.send(quietdesk_core::viewer::ViewerCommand::Disconnect).is_ok();
            let end = tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(session).unwrap_or_else(|error| fail("viewer task", error));
            let counts = report.0.lock().unwrap();
            let pictures = counts.pictures;
            // The opening picture was decoded before commit and is published by the commit itself.
            let after_commit = counts.media_pictures.saturating_sub(1);
            let frame = frame.lock().unwrap();
            println!(
                "viewer ended: {} pictures={pictures} after_commit={after_commit} last={}x{} serial={}",
                end.reason, frame.width, frame.height, frame.serial
            );
            if arguments.iter().any(|argument| argument == "--require-media") {
                if !disconnected || end.reason != "已断开连接" {
                    fail("viewer", "session ended before the requested disconnect");
                }
                if counts.showed_candidate {
                    fail("viewer", "displayed a media picture before its stream committed");
                }
                if after_commit == 0 {
                    fail("viewer", "no picture decoded after the shared media stream committed");
                }
            }
            if pictures > 0 && frame.width > 0 { println!("PASS viewer") } else { fail("viewer", "no picture was decoded") }
        }
        _ => {
            println!(
                "usage: quietdesk-wincheck capture | codec | host --code C [--port P] [--seconds S] | viewer --code C [--host H] [--port P] [--seconds S] [--require-media]"
            )
        }
    }
}
