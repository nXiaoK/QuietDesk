//! Asynchronous H.264 encoding on the adapter that owns the capture texture.

use super::*;
use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr::{self, from_ref};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{E_FAIL, E_NOTIMPL, E_POINTER};
use windows::Win32::Graphics::Direct3D11::{ID3D11Device, ID3D11Multithread, ID3D11Texture2D};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Media::MediaFoundation::{MEError as ERROR_EVENT, METransformHaveOutput as HAVE_OUTPUT, METransformNeedInput as NEED_INPUT};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
use windows::core::{s, w};

type EnumForAdapter = unsafe extern "system" fn(
    GUID,
    u32,
    *const MFT_REGISTER_TYPE_INFO,
    *const MFT_REGISTER_TYPE_INFO,
    *mut c_void,
    *mut *mut Option<IMFActivate>,
    *mut u32,
) -> HRESULT;

fn hardware_encoders(device: &ID3D11Device) -> windows::core::Result<Vec<IMFActivate>> {
    unsafe {
        // Earlier Windows 10 versions keep loading even when this optional export is absent.
        let library = GetModuleHandleW(w!("mfplat.dll"))?;
        let entry = GetProcAddress(library, s!("MFTEnum2")).ok_or(E_NOTIMPL)?;
        let find: EnumForAdapter = std::mem::transmute(entry);
        let adapter = device.cast::<IDXGIDevice>()?.GetAdapter()?.GetDesc()?.AdapterLuid;
        let mut attributes = None;
        MFCreateAttributes(&mut attributes, 1)?;
        let attributes = attributes.ok_or(E_POINTER)?;
        attributes.SetBlob(&MFT_ENUM_ADAPTER_LUID, std::slice::from_raw_parts(from_ref(&adapter).cast(), size_of_val(&adapter)))?;

        let input = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_NV12 };
        let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_H264 };
        let mut encoders = ptr::null_mut();
        let mut count = 0;
        let flags = (MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER).0 as u32;
        find(MFT_CATEGORY_VIDEO_ENCODER, flags, &input, &output, attributes.as_raw(), &mut encoders, &mut count).ok()?;
        let matches =
            if count == 0 { Vec::new() } else { std::slice::from_raw_parts_mut(encoders, count as usize).iter_mut().filter_map(Option::take).collect() };
        CoTaskMemFree(Some(encoders.cast()));
        Ok(matches)
    }
}

struct SubmittedFrame {
    time: i64,
    started_at: Instant,
    needs_idr: bool,
}

struct EncoderTransform {
    activate: IMFActivate,
    transform: IMFTransform,
    events: IMFMediaEventGenerator,
    control: ICodecAPI,
    _manager: IMFDXGIDeviceManager,
}

impl Drop for EncoderTransform {
    fn drop(&mut self) {
        let _ = unsafe { self.activate.ShutdownObject() };
    }
}

pub struct H264HardwareEncoder {
    driver: Option<EncoderTransform>,
    assembler: H264FrameAssembler,
    input_id: u32,
    output_id: u32,
    size: (u32, u32),
    duration: i64,
    next_time: i64,
    wanted_inputs: usize,
    key_frame_wanted: bool,
    waiting_for_input_since: Option<Instant>,
    in_flight: VecDeque<SubmittedFrame>,
    encode_elapsed: Option<Duration>,
}

impl H264HardwareEncoder {
    const MAX_IN_FLIGHT: usize = 2;
    const STALL_LIMIT: Duration = Duration::from_millis(500);

    pub fn new(width: u32, height: u32, settings: StreamSettings, device: &ID3D11Device) -> Result<Self> {
        let matches = hardware_encoders(device).map_err(failed("枚举同一显卡上的 H.264 编码器"))?;
        let mut rejection = DeskError::platform("当前显卡没有可用的 H.264 硬件编码器");
        for activate in matches {
            match Self::configure(&activate, device, width, height, settings) {
                Ok(encoder) => return Ok(encoder),
                Err(error) => {
                    let _ = unsafe { activate.ShutdownObject() };
                    log::debug!("hardware encoder candidate declined: {error}");
                    rejection = error;
                }
            }
        }
        Err(rejection)
    }

    fn configure(activate: &IMFActivate, device: &ID3D11Device, width: u32, height: u32, settings: StreamSettings) -> Result<Self> {
        let (rate, bits) = encoder_rate(settings);
        let configure = || -> windows::core::Result<Self> {
            unsafe {
                let transform: IMFTransform = activate.ActivateObject()?;
                let events = transform.cast::<IMFMediaEventGenerator>()?;
                let attrs = transform.GetAttributes()?;
                if attrs.GetUINT32(&MF_SA_D3D11_AWARE)? == 0 {
                    return Err(E_NOTIMPL.into());
                }
                attrs.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
                let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);

                let (mut input_count, mut output_count) = (0, 0);
                transform.GetStreamCount(&mut input_count, &mut output_count)?;
                if input_count != 1 || output_count != 1 {
                    return Err(E_NOTIMPL.into());
                }
                let (mut input_id, mut output_id) = (0, 0);
                if let Err(error) = transform.GetStreamIDs(std::slice::from_mut(&mut input_id), std::slice::from_mut(&mut output_id))
                    && error.code() != E_NOTIMPL
                {
                    return Err(error);
                }

                // The transform accesses this immediate context from Media Foundation worker threads.
                let _ = device.GetImmediateContext()?.cast::<ID3D11Multithread>()?.SetMultithreadProtected(true);
                let (mut token, mut manager) = (0, None);
                MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
                let manager = manager.ok_or(E_POINTER)?;
                manager.ResetDevice(device, token)?;
                transform.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, manager.as_raw() as usize)?;

                let control = transform.cast::<ICodecAPI>()?;
                for (label, name, value) in encoder_options(rate, bits) {
                    let status = codec_option(&control, name, &value);
                    if status != S_OK {
                        log::debug!("hardware encoder option {label} was not accepted: {status:?}");
                    }
                }
                let (input, output) = encoder_types(width, height, rate, bits)?;
                transform.SetOutputType(output_id, &output, 0)?;
                transform.SetInputType(input_id, &input, 0)?;
                transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
                transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
                Ok(Self {
                    driver: Some(EncoderTransform { activate: activate.clone(), transform, events, control, _manager: manager }),
                    assembler: H264FrameAssembler::default(),
                    input_id,
                    output_id,
                    size: (width, height),
                    duration: 10_000_000 / i64::from(rate),
                    next_time: 0,
                    wanted_inputs: 0,
                    key_frame_wanted: false,
                    waiting_for_input_since: None,
                    in_flight: VecDeque::with_capacity(Self::MAX_IN_FLIGHT),
                    encode_elapsed: None,
                })
            }
        };
        configure().map_err(failed(&format!("配置 H.264 硬件编码器（{width}×{height}）")))
    }

    /// Releases the previous MFT before opening another. On failure the capture loop starts software encoding.
    pub fn restart(&mut self, settings: StreamSettings, device: &ID3D11Device) -> Result<()> {
        let (width, height) = self.size;
        self.driver = None;
        *self = Self::new(width, height, settings, device)?;
        Ok(())
    }

    fn driver(&self) -> &EncoderTransform {
        self.driver.as_ref().expect("failed hardware restarts return to the software path")
    }

    pub fn set_bitrate(&mut self, megabits: i64) -> Result<()> {
        set_encoder_bitrate(&self.driver().control, megabits)
    }

    pub fn request_key_frame(&mut self) {
        self.key_frame_wanted = true;
    }

    pub fn pending(&self) -> u32 {
        self.in_flight.len() as u32
    }

    pub fn can_submit(&self) -> bool {
        self.wanted_inputs != 0 && self.in_flight.len() < Self::MAX_IN_FLIGHT
    }

    /// Each input texture belongs to one sample and remains immutable while the transform holds it.
    pub fn submit(&mut self, texture: &ID3D11Texture2D) -> Result<bool> {
        if !self.can_submit() {
            return Ok(false);
        }
        let driver = self.driver();
        if self.key_frame_wanted && self.next_time != 0 {
            let status = codec_option(&driver.control, &CODECAPI_AVEncVideoForceKeyFrame, &VARIANT::from(1u32));
            if status != S_OK {
                return Err(DeskError::platform(format!("硬件编码器未接受关键帧请求：{status:?}")));
            }
        }
        let input = || -> windows::core::Result<Instant> {
            unsafe {
                let buffer = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, texture, 0, false)?;
                buffer.SetCurrentLength(buffer.GetMaxLength()?)?;
                let sample = MFCreateSample()?;
                sample.AddBuffer(&buffer)?;
                sample.SetSampleTime(self.next_time)?;
                sample.SetSampleDuration(self.duration)?;
                let started_at = Instant::now();
                driver.transform.ProcessInput(self.input_id, &sample, 0)?;
                Ok(started_at)
            }
        };
        let started_at = input().map_err(failed("提交 H.264 硬件编码输入"))?;
        self.in_flight.push_back(SubmittedFrame { time: self.next_time, started_at, needs_idr: self.next_time == 0 || self.key_frame_wanted });
        self.next_time += self.duration;
        self.wanted_inputs -= 1;
        self.key_frame_wanted = false;
        Ok(true)
    }

    pub fn take_encode_elapsed(&mut self) -> Option<Duration> {
        self.encode_elapsed.take()
    }

    pub fn poll(&mut self, frames: &mut Vec<EncodedFrame>) -> Result<()> {
        frames.clear();
        self.encode_elapsed = None;
        // Limit the work done on the capture thread even if a driver keeps posting events.
        for _ in 0..32 {
            let event = match unsafe { self.driver().events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(event) => event,
                Err(error) if error.code() == MF_E_NO_EVENTS_AVAILABLE => break,
                Err(error) => return Err(failed("轮询 H.264 硬件编码器")(error)),
            };
            let event_type = unsafe { event.GetStatus().and_then(HRESULT::ok).and_then(|()| event.GetType()) }.map_err(failed("处理 H.264 硬件编码事件"))?;
            match MF_EVENT_TYPE(event_type as i32) {
                NEED_INPUT => self.wanted_inputs += 1,
                HAVE_OUTPUT => frames.extend(self.picture()?),
                ERROR_EVENT => return Err(failed("处理 H.264 硬件编码事件")(E_FAIL.into())),
                _ => {}
            }
        }
        if let Some(frame) = self.in_flight.front() {
            if frame.started_at.elapsed() > Self::STALL_LIMIT {
                return Err(DeskError::platform("H.264 硬件编码没有按时输出"));
            }
        } else if self.wanted_inputs == 0 {
            if self.waiting_for_input_since.get_or_insert_with(Instant::now).elapsed() > Self::STALL_LIMIT {
                return Err(DeskError::platform("H.264 硬件编码没有请求输入"));
            }
        } else {
            self.waiting_for_input_since = None;
        }
        Ok(())
    }

    fn picture(&mut self) -> Result<Option<EncodedFrame>> {
        let driver = self.driver.as_ref().expect("the event queue belongs to a running hardware encoder");
        let output = match unsafe { take_output(&driver.transform, self.output_id) } {
            Ok(Some(output)) => output,
            Ok(None) => return Ok(None),
            Err(error) if error.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                self.refresh_output_type().map_err(failed("更新 H.264 硬件编码输出格式"))?;
                return Ok(None);
            }
            Err(error) => return Err(failed("读取 H.264 硬件编码输出")(error)),
        };
        let ready_at = Instant::now();
        let time = match unsafe { output.GetSampleTime() } {
            Ok(time) => Some(time),
            Err(error) if error.code() == MF_E_NO_SAMPLE_TIMESTAMP => None,
            Err(error) => return Err(failed("读取 H.264 硬件编码时间")(error)),
        };
        let picture = unsafe { assemble_output(&driver.transform, self.output_id, &mut self.assembler, output) }?;
        let Some(picture) = picture else { return Ok(None) };
        let (input, needs_idr) = take_picture_input(&mut self.in_flight, time)?;
        if needs_idr && !picture.is_key_frame() {
            return Err(DeskError::platform("H.264 硬件编码没有生成所需的关键帧"));
        }
        self.encode_elapsed = Some(ready_at.duration_since(input.started_at));
        Ok(Some(picture))
    }

    fn refresh_output_type(&self) -> windows::core::Result<()> {
        unsafe {
            let transform = &self.driver().transform;
            let size = pack(self.size.0, self.size.1);
            let mut index = 0;
            loop {
                let output = transform.GetOutputAvailableType(self.output_id, index)?;
                if output.GetGUID(&MF_MT_SUBTYPE).ok() == Some(MFVideoFormat_H264) && output.GetUINT64(&MF_MT_FRAME_SIZE).ok() == Some(size) {
                    return transform.SetOutputType(self.output_id, &output, 0);
                }
                index += 1;
            }
        }
    }
}

fn take_picture_input(in_flight: &mut VecDeque<SubmittedFrame>, time: Option<i64>) -> Result<(SubmittedFrame, bool)> {
    // A matching timestamp identifies an input even when the hardware dropped an older frame.
    let unmatched = || DeskError::platform("H.264 硬件编码输出没有对应的输入帧");
    let index = match time {
        Some(time) => in_flight.iter().position(|input| input.time == time).ok_or_else(unmatched)?,
        None => 0,
    };
    let mut processed = in_flight.drain(..(index + 1).min(in_flight.len()));
    let input = processed.next_back().ok_or_else(unmatched)?;
    let needs_idr = input.needs_idr || processed.any(|frame| frame.needs_idr);
    Ok((input, needs_idr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_skipped_input_keeps_the_keyframe_requirement_and_matches_real_encode_time() {
        let started_at = Instant::now();
        let mut in_flight = VecDeque::from([
            SubmittedFrame { time: 0, started_at, needs_idr: true },
            SubmittedFrame { time: 1, started_at: started_at + Duration::from_millis(10), needs_idr: false },
        ]);
        let (input, needs_idr) = take_picture_input(&mut in_flight, Some(1)).unwrap();
        assert_eq!(input.started_at, started_at + Duration::from_millis(10));
        assert!(needs_idr);
        assert!(in_flight.is_empty());
        assert!(take_picture_input(&mut in_flight, None).is_err());
    }

    #[test]
    fn a_stale_timestamp_cannot_consume_a_new_input() {
        let started_at = Instant::now();
        let mut in_flight = VecDeque::from([SubmittedFrame { time: 1, started_at, needs_idr: false }]);
        assert!(take_picture_input(&mut in_flight, Some(0)).is_err());
        let (input, _) = take_picture_input(&mut in_flight, None).unwrap();
        assert_eq!(input.time, 1);
    }
}
