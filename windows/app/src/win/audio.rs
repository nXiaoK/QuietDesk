//! Shared-mode audio on the default render endpoint. The capture client taps its system mix.
use quietdesk_core::audio::{AudioEncoder, AudioPacket, AudioPlayout, CHANNELS, FRAMES_PER_PACKET, INTERLEAVED_SAMPLES, SAMPLE_RATE};
use quietdesk_core::audio_session::{AudioCapture, AudioPlayback, AudioRunState, CaptureEvent, CaptureWorker, PlaybackEvent, PlaybackWorker};
use quietdesk_core::error::{DeskError, Result};
use std::num::NonZeroU32;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};
use windows::Win32::Foundation::{CloseHandle, E_POINTER, HANDLE, WAIT_FAILED};
use windows::Win32::Media::Audio::*;
use windows::Win32::Media::Multimedia::WAVE_FORMAT_IEEE_FLOAT;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};
use windows::core::{Error as WinError, Interface, Result as WinResult};

pub(super) fn start_capture(epoch: NonZeroU32, redundant: bool, paused: bool) -> Result<AudioCapture> {
    let (capture, worker) = AudioCapture::channel(paused);
    std::thread::Builder::new()
        .name("quietdesk-audio-capture".into())
        .spawn(move || {
            let events = worker.events.clone();
            if let Err(error) = capture_worker(epoch, redundant, worker) {
                let _ = events.blocking_send(CaptureEvent::Failed(error));
            }
        })
        .map_err(|_| DeskError::platform("无法启动系统声音采集线程"))?;
    Ok(capture)
}

pub(super) fn start_playback(epoch: NonZeroU32, paused: bool) -> Result<AudioPlayback> {
    let (playback, worker) = AudioPlayback::channel(paused);
    std::thread::Builder::new()
        .name("quietdesk-audio-playback".into())
        .spawn(move || {
            let events = worker.events.clone();
            if let Err(error) = playback_worker(epoch, worker) {
                let _ = events.blocking_send(PlaybackEvent::Failed(error));
            }
        })
        .map_err(|_| DeskError::platform("无法启动声音播放线程"))?;
    Ok(playback)
}

fn capture_worker(epoch: NonZeroU32, redundant: bool, worker: CaptureWorker) -> Result<()> {
    let CaptureWorker { events, paused } = worker;
    let mut capture = Capture { encoder: AudioEncoder::new(epoch, redundant)?, pcm: [0.0; INTERLEAVED_SAMPLES], filled: 0, events };
    run(&mut capture, paused)
}

fn playback_worker(epoch: NonZeroU32, worker: PlaybackWorker) -> Result<()> {
    let PlaybackWorker { packets, events, paused } = worker;
    let mut playback = Playback { decoder: AudioPlayout::new(epoch)?, epoch, packets, events, staged: None };
    run(&mut playback, paused)
}

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() }
    }
}

struct Event(HANDLE);
impl Drop for Event {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

struct Stream<T> {
    service: T,
    client: IAudioClient,
    event: Event,
    capacity: u32,
    revision: u64,
    id: Vec<u16>,
}

impl<T: Interface> Stream<T> {
    fn open(device: &IMMDevice, flags: u32, revision: u64) -> WinResult<Self> {
        unsafe {
            let id = device_id(device)?;
            let client: IAudioClient = device.Activate(CLSCTX_INPROC_SERVER, None)?;
            let format = WAVEFORMATEX {
                wFormatTag: WAVE_FORMAT_IEEE_FLOAT as u16,
                nChannels: CHANNELS as u16,
                nSamplesPerSec: SAMPLE_RATE,
                nAvgBytesPerSec: SAMPLE_RATE * 8,
                nBlockAlign: 8,
                wBitsPerSample: 32,
                cbSize: 0,
            };
            let flags = flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
            client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 600_000, 0, &format, None)?;
            let event = Event(CreateEventW(None, false, false, None)?);
            client.SetEventHandle(event.0)?;
            let service = client.GetService()?;
            let capacity = client.GetBufferSize()?;
            Ok(Self { service, client, event, capacity, revision, id })
        }
    }
}

impl<T> Drop for Stream<T> {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
        }
    }
}

fn device_id(device: &IMMDevice) -> WinResult<Vec<u16>> {
    unsafe {
        let id = device.GetId()?;
        let owned = id.as_wide().to_owned();
        CoTaskMemFree(Some(id.as_ptr().cast()));
        Ok(owned)
    }
}

enum PumpError {
    Device(WinError),
    Codec(DeskError),
}

impl From<WinError> for PumpError {
    fn from(e: WinError) -> Self {
        Self::Device(e)
    }
}
impl From<DeskError> for PumpError {
    fn from(e: DeskError) -> Self {
        Self::Codec(e)
    }
}

trait Pump {
    type Service: Interface;
    const FLAGS: u32;
    fn ready(&self) -> bool;
    fn clear(&mut self) -> Result<()>;
    /// Returns true when the engine already has another packet to service.
    fn transfer(&mut self, stream: &Stream<Self::Service>) -> std::result::Result<bool, PumpError>;
}

fn device_error(error: WinError) -> DeskError {
    DeskError::platform(format!("系统声音设备不可用（0x{:08X}）", error.code().0))
}

fn run<P: Pump>(pump: &mut P, mut paused: watch::Receiver<AudioRunState>) -> Result<()> {
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() }.map_err(device_error)?;
    let _apartment = Apartment;
    let devices: IMMDeviceEnumerator = unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_INPROC_SERVER) }.map_err(device_error)?;
    let default = || unsafe { devices.GetDefaultAudioEndpoint(eRender, eConsole) };
    let runtime = tokio::runtime::Builder::new_current_thread().build().map_err(|_| DeskError::platform("无法等待声音设备恢复"))?;
    let mut ready = false;
    let mut last_recovery = None;
    loop {
        if paused.has_changed().is_err() {
            return Ok(());
        }
        let state = *paused.borrow_and_update();
        if !ready || !state.paused {
            let device = default().map_err(device_error)?;
            let stream = Stream::open(&device, P::FLAGS, state.revision).map_err(device_error)?;
            if !state.paused {
                unsafe { stream.client.Start() }.map_err(device_error)?;
            }
            if !ready {
                if !pump.ready() {
                    return Ok(());
                }
                ready = true;
            }
            if !state.paused {
                let mut check_default = Instant::now() + Duration::from_secs(1);
                while matches!(paused.has_changed(), Ok(false)) {
                    if Instant::now() >= check_default {
                        if device_id(&default().map_err(device_error)?).map_err(device_error)? != stream.id {
                            break;
                        }
                        check_default = Instant::now() + Duration::from_secs(1);
                    }
                    match pump.transfer(&stream) {
                        Ok(true) => continue,
                        Ok(false) => {}
                        Err(error) => match error {
                            PumpError::Device(e)
                                if matches!(e.code(), AUDCLNT_E_DEVICE_INVALIDATED | AUDCLNT_E_RESOURCES_INVALIDATED)
                                    && last_recovery.is_none_or(|t: Instant| t.elapsed() >= Duration::from_secs(1)) =>
                            {
                                last_recovery = Some(Instant::now());
                                break;
                            }
                            PumpError::Device(e) => return Err(device_error(e)),
                            PumpError::Codec(e) => return Err(e),
                        },
                    }
                    // Also observe stop/pause when a silent device produces no event.
                    if unsafe { WaitForSingleObject(stream.event.0, 20) } == WAIT_FAILED {
                        return Err(device_error(WinError::from_thread()));
                    }
                }
            }
        }
        pump.clear()?;
        if state.paused {
            if runtime.block_on(paused.changed()).is_err() {
                return Ok(());
            }
            pump.clear()?;
        }
    }
}

struct Capture {
    encoder: AudioEncoder,
    pcm: [f32; INTERLEAVED_SAMPLES],
    filled: usize,
    events: mpsc::Sender<CaptureEvent>,
}

impl Pump for Capture {
    type Service = IAudioCaptureClient;
    const FLAGS: u32 = AUDCLNT_STREAMFLAGS_LOOPBACK;
    fn ready(&self) -> bool {
        self.events.blocking_send(CaptureEvent::Ready).is_ok()
    }
    fn clear(&mut self) -> Result<()> {
        self.filled = 0;
        self.encoder.reset_after_pause()
    }
    fn transfer(&mut self, stream: &Stream<Self::Service>) -> std::result::Result<bool, PumpError> {
        let client = &stream.service;
        // Service one engine packet per turn so endpoint and session changes cannot starve.
        unsafe {
            if client.GetNextPacketSize()? == 0 {
                return Ok(false);
            }
            let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0, 0);
            client.GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
            if frames == 0 {
                return Ok(false);
            }
            let samples = frames as usize * CHANNELS;
            let processed = (|| {
                if flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0 {
                    self.clear()?;
                }
                let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
                if !silent && data.is_null() {
                    return Err(PumpError::Device(WinError::from_hresult(E_POINTER)));
                }
                let mut offset = 0;
                while offset < samples {
                    let count = (INTERLEAVED_SAMPLES - self.filled).min(samples - offset);
                    let part = &mut self.pcm[self.filled..self.filled + count];
                    if silent {
                        part.fill(0.0);
                    } else {
                        part.copy_from_slice(std::slice::from_raw_parts(data.cast::<f32>().add(offset), count));
                    }
                    offset += count;
                    self.filled += count;
                    if self.filled == INTERLEAVED_SAMPLES {
                        let packet = self.encoder.encode(&self.pcm)?;
                        self.filled = 0;
                        let _ = self.events.try_send(CaptureEvent::Packet(packet, stream.revision));
                    }
                }
                Ok(())
            })();
            client.ReleaseBuffer(frames)?;
            processed?;
            Ok(client.GetNextPacketSize()? != 0)
        }
    }
}

struct Playback {
    decoder: AudioPlayout,
    epoch: NonZeroU32,
    packets: mpsc::Receiver<AudioPacket>,
    events: mpsc::Sender<PlaybackEvent>,
    staged: Option<([f32; INTERLEAVED_SAMPLES], usize)>,
}

impl Pump for Playback {
    type Service = IAudioRenderClient;
    const FLAGS: u32 = 0;
    fn ready(&self) -> bool {
        self.events.blocking_send(PlaybackEvent::Ready).is_ok()
    }
    fn clear(&mut self) -> Result<()> {
        self.staged = None;
        for _ in 0..self.packets.len() {
            let _ = self.packets.try_recv();
        }
        self.decoder.reset(self.epoch)
    }
    fn transfer(&mut self, stream: &Stream<Self::Service>) -> std::result::Result<bool, PumpError> {
        unsafe {
            let mut padding = stream.client.GetCurrentPadding()?;
            let remaining = self.staged.as_ref().map_or(0, |(_, offset)| FRAMES_PER_PACKET - offset);
            let in_flight = (padding as usize + remaining).div_ceil(FRAMES_PER_PACKET);
            for _ in 0..self.packets.len() {
                if let Ok(packet) = self.packets.try_recv() {
                    self.decoder.push(packet, in_flight);
                }
            }
            while padding < stream.capacity {
                if self.staged.is_none() {
                    let Some(frame) = self.decoder.next((padding as usize).div_ceil(FRAMES_PER_PACKET))? else { break };
                    self.staged = Some((frame, 0));
                }
                let (pcm, offset) = self.staged.as_mut().expect("a decoded audio packet is staged");
                let frames = (FRAMES_PER_PACKET - *offset).min((stream.capacity - padding) as usize);
                let buffer = stream.service.GetBuffer(frames as u32)?;
                if buffer.is_null() {
                    stream.service.ReleaseBuffer(0, 0)?;
                    return Err(WinError::from_hresult(E_POINTER).into());
                }
                std::ptr::copy_nonoverlapping(pcm.as_ptr().add(*offset * CHANNELS), buffer.cast::<f32>(), frames * CHANNELS);
                stream.service.ReleaseBuffer(frames as u32, 0)?;
                padding += frames as u32;
                *offset += frames;
                if *offset == FRAMES_PER_PACKET {
                    self.staged = None;
                }
            }
        }
        Ok(false)
    }
}

#[cfg(test)]
mod tests;
