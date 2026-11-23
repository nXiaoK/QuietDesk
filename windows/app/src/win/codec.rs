//! H.264 through the Media Foundation transforms that ship with Windows.

use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use quietdesk_core::messages::StreamSettings;
use quietdesk_core::pixel::Plane;
use quietdesk_core::video::{EncodedFrame, H264FrameAssembler};
use std::mem::ManuallyDrop;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance, CoTaskMemFree};
use windows::Win32::System::Variant::VARIANT;
use windows::core::{GUID, Interface};

/// Media Foundation for the current process, shut down when dropped.
pub struct MediaFoundation;

impl MediaFoundation {
    pub fn start() -> Result<Self> {
        unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }.map_err(failed("启动 Media Foundation"))?;
        Ok(Self)
    }
}

impl Drop for MediaFoundation {
    fn drop(&mut self) {
        let _ = unsafe { MFShutdown() };
    }
}

fn pack(high: u32, low: u32) -> u64 {
    u64::from(high) << 32 | u64::from(low)
}

unsafe fn video_type(subtype: &GUID) -> windows::core::Result<IMFMediaType> {
    unsafe {
        let media_type = MFCreateMediaType()?;
        media_type.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        media_type.SetGUID(&MF_MT_SUBTYPE, subtype)?;
        Ok(media_type)
    }
}

unsafe fn sample_with(bytes: &[u8], time: i64, duration: i64) -> windows::core::Result<IMFSample> {
    unsafe {
        let buffer = MFCreateMemoryBuffer(bytes.len() as u32)?;
        let mut data = std::ptr::null_mut();
        buffer.Lock(&mut data, None, None)?;
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
        buffer.Unlock()?;
        buffer.SetCurrentLength(bytes.len() as u32)?;
        let sample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        sample.SetSampleTime(time)?;
        sample.SetSampleDuration(duration)?;
        Ok(sample)
    }
}

/// One `ProcessOutput` call. `Ok(None)` means the transform wants more input.
unsafe fn take_output(transform: &IMFTransform) -> windows::core::Result<Option<IMFSample>> {
    unsafe {
        let info = transform.GetOutputStreamInfo(0)?;
        let provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32 != 0;
        let own = if provides {
            None
        } else {
            let sample = MFCreateSample()?;
            sample.AddBuffer(&MFCreateMemoryBuffer(info.cbSize.max(1 << 16))?)?;
            Some(sample)
        };
        let mut output = MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(own), dwStatus: 0, pEvents: ManuallyDrop::new(None) };
        let mut status = 0;
        let result = transform.ProcessOutput(0, std::slice::from_mut(&mut output), &mut status);
        let sample = ManuallyDrop::take(&mut output.pSample);
        ManuallyDrop::drop(&mut output.pEvents);
        match result {
            Ok(()) => Ok(sample),
            Err(error) if error.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => Ok(None),
            Err(error) => Err(error),
        }
    }
}

fn drain_access_units<T>(
    mut next: impl FnMut() -> Result<Option<T>>,
    mut assemble: impl FnMut(T) -> Result<Option<EncodedFrame>>,
    frames: &mut Vec<EncodedFrame>,
) -> Result<()> {
    while let Some(sample) = next()? {
        frames.extend(assemble(sample)?);
    }
    Ok(())
}

/// The Microsoft software H.264 encoder in low-latency mode.
pub struct H264Encoder {
    transform: IMFTransform,
    control: Option<ICodecAPI>,
    assembler: H264FrameAssembler,
    frame_duration: i64,
    frames: i64,
    key_frame_wanted: bool,
    /// Frames taken in that have not come out yet.
    pending: u32,
    size: (u32, u32),
    settings: StreamSettings,
}

// Used by the capture thread alone.
unsafe impl Send for H264Encoder {}

impl H264Encoder {
    pub fn new(width: u32, height: u32, settings: StreamSettings) -> Result<Self> {
        let rate = settings.frames_per_second.clamp(1, 60) as u32;
        let bits = (settings.megabits.clamp(1, 100) * 1_000_000) as u32;
        unsafe {
            let transform: IMFTransform = CoCreateInstance(&CLSID_MSH264EncoderMFT, None, CLSCTX_INPROC_SERVER).map_err(failed("创建 H.264 编码器"))?;
            // The encoder reads these when its output type is set; set later, low-latency mode is ignored and
            // it holds more than a dozen frames back before the first one comes out.
            let control = transform.cast::<ICodecAPI>().ok();
            if let Some(control) = &control {
                let options: [(&str, &GUID, VARIANT); 5] = [
                    ("low latency", &CODECAPI_AVLowLatencyMode, VARIANT::from(true)),
                    ("constant bit rate", &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32)),
                    ("bit rate", &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bits)),
                    ("no B frames", &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32)),
                    // Keyframes are sent when a stream starts or resumes, not on a schedule.
                    ("keyframe distance", &CODECAPI_AVEncMPVGOPSize, VARIANT::from(rate * 3600)),
                ];
                for (label, name, value) in &options {
                    if let Err(error) = control.SetValue(*name, std::ptr::from_ref(value).cast()) {
                        log::warn!("encoder option {label} was not accepted: {error}");
                    }
                }
            }
            let configure = || -> windows::core::Result<()> {
                let output = video_type(&MFVideoFormat_H264)?;
                output.SetUINT32(&MF_MT_AVG_BITRATE, bits)?;
                output.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High.0 as u32)?;
                let input = video_type(&MFVideoFormat_NV12)?;
                for media_type in [&output, &input] {
                    media_type.SetUINT64(&MF_MT_FRAME_SIZE, pack(width, height))?;
                    media_type.SetUINT64(&MF_MT_FRAME_RATE, pack(rate, 1))?;
                    media_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
                    media_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
                    // The frames are BT.709 video range; an encoder that writes colour information says so.
                    media_type.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32)?;
                    media_type.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32)?;
                    media_type.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32)?;
                    media_type.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
                }
                // The encoder accepts an input type only once it knows what it will produce.
                transform.SetOutputType(0, &output, 0)?;
                transform.SetInputType(0, &input, 0)
            };
            configure().map_err(failed(&format!("配置 H.264 编码器（{width}×{height}）")))?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(failed("启动 H.264 编码器"))?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(failed("启动 H.264 编码器"))?;
            Ok(Self {
                transform,
                control,
                assembler: H264FrameAssembler::default(),
                frame_duration: 10_000_000 / i64::from(rate),
                frames: 0,
                key_frame_wanted: false,
                pending: 0,
                size: (width, height),
                settings,
            })
        }
    }

    pub fn request_key_frame(&mut self) {
        self.key_frame_wanted = true;
    }

    /// Frames the encoder has taken without producing their output yet; none for a low-latency encoder.
    pub fn pending(&self) -> u32 {
        self.pending
    }

    /// Starts the encoder over. The first frame of a new encoder is a keyframe on every implementation.
    pub fn restart(&mut self) -> Result<()> {
        *self = Self::new(self.size.0, self.size.1, self.settings)?;
        Ok(())
    }

    /// Encodes one NV12 frame and replaces the output buffer with all access units available in order.
    pub fn encode(&mut self, nv12: &[u8], frames: &mut Vec<EncodedFrame>) -> Result<()> {
        frames.clear();
        unsafe {
            if std::mem::take(&mut self.key_frame_wanted) && self.frames > 0 {
                let request = VARIANT::from(1u32);
                let forced = self
                    .control
                    .as_ref()
                    .is_some_and(|control| control.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, std::ptr::from_ref(&request).cast()).is_ok());
                if !forced {
                    log::info!("the encoder has no on-demand keyframes, starting it over for one");
                    self.restart()?;
                }
            }
            let sample = sample_with(nv12, self.frames * self.frame_duration, self.frame_duration).map_err(failed("准备编码输入"))?;
            self.frames += 1;
            self.transform.ProcessInput(0, &sample, 0).map_err(failed("提交编码输入"))?;
            self.pending += 1;
            let transform = &self.transform;
            let assembler = &mut self.assembler;
            let result = drain_access_units(
                || take_output(transform).map_err(failed("读取编码输出")),
                |output| {
                    let buffer = output.ConvertToContiguousBuffer().map_err(failed("读取编码输出"))?;
                    let (mut data, mut length) = (std::ptr::null_mut(), 0);
                    buffer.Lock(&mut data, None, Some(&mut length)).map_err(failed("读取编码输出"))?;
                    let stream = std::slice::from_raw_parts(data, length as usize);
                    let assembled = assembler.assemble(stream).or_else(|_| {
                        // Some encoders announce the parameter sets in the output type instead of the stream.
                        Self::announce_parameter_sets(transform, assembler);
                        assembler.assemble(stream)
                    });
                    let _ = buffer.Unlock();
                    assembled
                },
                frames,
            );
            self.pending = self.pending.saturating_sub(frames.len() as u32);
            if result.is_err() {
                frames.clear();
            }
            result
        }
    }

    unsafe fn announce_parameter_sets(transform: &IMFTransform, assembler: &mut H264FrameAssembler) {
        unsafe {
            let (mut data, mut length) = (std::ptr::null_mut(), 0);
            if let Ok(current) = transform.GetOutputCurrentType(0)
                && current.GetAllocatedBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut data, &mut length).is_ok()
            {
                assembler.set_parameter_sets(std::slice::from_raw_parts(data, length as usize));
                CoTaskMemFree(Some(data.cast()));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_batched_encoder_output_retains_the_idr_and_each_prediction_in_order() {
        let metadata: &[u8] = &[0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2];
        let idr: &[u8] = &[0, 0, 1, 0x65, 3];
        let first_prediction: &[u8] = &[0, 0, 1, 0x41, 4];
        let next_prediction: &[u8] = &[0, 0, 1, 0x41, 5];
        let mut samples = [metadata, idr, first_prediction, next_prediction].into_iter();
        let mut assembler = H264FrameAssembler::default();
        let mut frames = Vec::new();

        drain_access_units(|| Ok(samples.next()), |sample| assembler.assemble(sample), &mut frames).unwrap();

        assert_eq!(frames.iter().map(|frame| frame.avcc[5]).collect::<Vec<_>>(), [3, 4, 5]);
        assert!(frames[0].is_key_frame());
        assert_eq!(frames[0].sps, [0x67, 1]);
        assert_eq!(frames[0].pps, [0x68, 2]);
    }
}

/// A decoded picture, valid during the callback that receives it.
pub struct Picture<'a> {
    pub sample_time: Option<i64>,
    pub luma: Plane<'a>,
    pub chroma: Plane<'a>,
    pub width: usize,
    pub height: usize,
}

#[derive(Clone, Copy, Default)]
struct Layout {
    width: usize,
    height: usize,
    coded_height: usize,
    stride: usize,
}

/// The Microsoft H.264 decoder in low-latency mode, producing NV12 in system memory.
pub struct H264Decoder {
    transform: IMFTransform,
    layout: Layout,
    next_sample_time: i64,
}

// Used by the decode thread alone.
unsafe impl Send for H264Decoder {}

impl H264Decoder {
    // Input times identify pictures. The sender paces presentation, so this clock is independent
    // of screen capture rate. MFTs that synthesize output times use the input type's frame rate.
    const CLOCK_RATE: u32 = 30;
    const SAMPLE_DURATION: i64 = 10_000_000 / Self::CLOCK_RATE as i64;

    pub fn new() -> Result<Self> {
        unsafe {
            let transform: IMFTransform = CoCreateInstance(&CLSID_MSH264DecoderMFT, None, CLSCTX_INPROC_SERVER).map_err(failed("创建 H.264 解码器"))?;
            // Without this the decoder holds frames back for reordering the stream never uses.
            if let Ok(attributes) = transform.GetAttributes() {
                let _ = attributes.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            if let Ok(control) = transform.cast::<ICodecAPI>() {
                // The Microsoft H.264 decoder expects VT_UI4 for this option.
                let enabled = VARIANT::from(1u32);
                let _ = control.SetValue(&CODECAPI_AVLowLatencyMode, std::ptr::from_ref(&enabled).cast());
            }
            let input = video_type(&MFVideoFormat_H264).map_err(failed("配置 H.264 解码器"))?;
            input.SetUINT64(&MF_MT_FRAME_RATE, pack(Self::CLOCK_RATE, 1)).map_err(failed("配置解码时间基准"))?;
            transform.SetInputType(0, &input, 0).map_err(failed("配置 H.264 解码器"))?;
            let mut decoder = Self { transform, layout: Layout::default(), next_sample_time: 0 };
            decoder.choose_output().map_err(failed("配置 H.264 解码输出"))?;
            decoder.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(failed("启动 H.264 解码器"))?;
            decoder.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(failed("启动 H.264 解码器"))?;
            Ok(decoder)
        }
    }

    /// Selects NV12 among the output types and reads where the picture lies in the buffers it describes.
    unsafe fn choose_output(&mut self) -> windows::core::Result<()> {
        unsafe {
            let mut index = 0;
            let output = loop {
                let candidate = self.transform.GetOutputAvailableType(0, index)?;
                if candidate.GetGUID(&MF_MT_SUBTYPE)? == MFVideoFormat_NV12 {
                    break candidate;
                }
                index += 1;
            };
            self.transform.SetOutputType(0, &output, 0)?;
            let size = output.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
            let (coded_width, coded_height) = ((size >> 32) as usize, (size & 0xFFFF_FFFF) as usize);
            // The coded size is padded to whole macroblocks; the aperture is the picture inside it.
            let mut area = MFVideoArea::default();
            let aperture = output.GetBlob(
                &MF_MT_MINIMUM_DISPLAY_APERTURE,
                std::slice::from_raw_parts_mut(std::ptr::from_mut(&mut area).cast(), size_of::<MFVideoArea>()),
                None,
            );
            let (width, height) = match aperture {
                Ok(()) if area.Area.cx > 0 && area.Area.cy > 0 => (area.Area.cx as usize, area.Area.cy as usize),
                _ => (coded_width, coded_height),
            };
            let stride = output.GetUINT32(&MF_MT_DEFAULT_STRIDE).map_or(coded_width, |stride| (stride as i32).unsigned_abs() as usize);
            self.layout = Layout { width: width / 2 * 2, height: height / 2 * 2, coded_height, stride: stride.max(coded_width) };
            Ok(())
        }
    }

    pub fn next_sample_time(&self) -> i64 {
        self.next_sample_time
    }

    /// Decodes one access unit and hands every picture it completes to `picture`.
    pub fn decode(&mut self, annex_b: &[u8], mut picture: impl FnMut(Picture)) -> Result<()> {
        unsafe {
            let sample = sample_with(annex_b, self.next_sample_time, Self::SAMPLE_DURATION).map_err(failed("准备解码输入"))?;
            self.next_sample_time += Self::SAMPLE_DURATION;
            let mut submitted = false;
            loop {
                if !submitted {
                    match self.transform.ProcessInput(0, &sample, 0) {
                        Ok(()) => submitted = true,
                        // The decoder first wants its finished pictures collected.
                        Err(error) if error.code() == MF_E_NOTACCEPTING => {}
                        Err(error) => return Err(failed("提交解码输入")(error)),
                    }
                }
                let output = match take_output(&self.transform) {
                    Ok(Some(output)) => output,
                    Ok(None) if submitted => return Ok(()),
                    Ok(None) => return Err(DeskError::platform("H.264 解码器既不接受输入也没有输出")),
                    Err(error) if error.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                        self.choose_output().map_err(failed("更新解码输出格式"))?;
                        continue;
                    }
                    Err(error) => return Err(failed("读取解码输出")(error)),
                };
                let layout = self.layout;
                if layout.width < 2 || layout.height < 2 {
                    continue;
                }
                let sample_time = output.GetSampleTime().ok();
                let buffer = output.ConvertToContiguousBuffer().map_err(failed("读取解码输出"))?;
                let (mut data, mut length) = (std::ptr::null_mut(), 0);
                buffer.Lock(&mut data, None, Some(&mut length)).map_err(failed("读取解码输出"))?;
                let bytes = std::slice::from_raw_parts(data, length as usize);
                let chroma_start = layout.stride * layout.coded_height;
                if bytes.len() >= chroma_start + layout.stride * (layout.height / 2 - 1) + layout.width {
                    picture(Picture {
                        sample_time,
                        luma: Plane { data: &bytes[..chroma_start], stride: layout.stride },
                        chroma: Plane { data: &bytes[chroma_start..], stride: layout.stride },
                        width: layout.width,
                        height: layout.height,
                    });
                } else {
                    log::warn!(
                        "decoded buffer of {} bytes does not hold a {}x{} picture with stride {}",
                        bytes.len(),
                        layout.width,
                        layout.height,
                        layout.stride
                    );
                }
                let _ = buffer.Unlock();
            }
        }
    }
}
