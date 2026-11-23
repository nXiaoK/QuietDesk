//! On the desktop duplication device, scale BGRA directly into an NV12 encoder surface.

use super::util::failed;
use quietdesk_core::error::{DeskError, Result};
use std::mem::ManuallyDrop;
use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::core::Interface;

pub(super) struct GpuScaler {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    video_device: ID3D11VideoDevice,
    video_context: ID3D11VideoContext1,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
    input: Option<(ID3D11Texture2D, ID3D11VideoProcessorInputView)>,
    output: ID3D11Texture2D,
    output_view: ID3D11VideoProcessorOutputView,
    staging: Option<ID3D11Texture2D>,
    size: (u32, u32),
}

impl GpuScaler {
    pub(super) fn new(device: &ID3D11Device, source: (u32, u32), size: (u32, u32), fps: u32) -> Result<Self> {
        let initialize = failed("初始化 GPU 缩放");
        let frame_rate = DXGI_RATIONAL { Numerator: fps, Denominator: 1 };
        // Match the software converter and the encoder's advertised BT.709 video range.
        let source_color = DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
        let target_color = DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709;
        unsafe {
            let context = device.GetImmediateContext().map_err(&initialize)?;
            let video_device: ID3D11VideoDevice = device.cast().map_err(&initialize)?;
            let video_context: ID3D11VideoContext1 = context.cast().map_err(&initialize)?;
            let enumerator = video_device
                .CreateVideoProcessorEnumerator(&D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                    InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                    InputFrameRate: frame_rate,
                    InputWidth: source.0,
                    InputHeight: source.1,
                    OutputFrameRate: frame_rate,
                    OutputWidth: size.0,
                    OutputHeight: size.1,
                    Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
                })
                .map_err(&initialize)?;
            let formats: ID3D11VideoProcessorEnumerator1 = enumerator.cast().map_err(&initialize)?;
            if !formats
                .CheckVideoProcessorFormatConversion(DXGI_FORMAT_B8G8R8A8_UNORM, source_color, DXGI_FORMAT_NV12, target_color)
                .map_err(&initialize)?
                .as_bool()
            {
                return Err(DeskError::platform("GPU 不支持 BT.709 视频范围转换"));
            }
            let processor = video_device.CreateVideoProcessor(&enumerator, 0).map_err(&initialize)?;
            let output = nv12_texture(device, size, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET.0 as u32, 0)?;
            let mut output_view = None;
            video_device
                .CreateVideoProcessorOutputView(
                    &output,
                    &enumerator,
                    &D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC { ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D, ..Default::default() },
                    Some(&mut output_view),
                )
                .map_err(&initialize)?;
            let output_view = output_view.ok_or_else(|| DeskError::platform("没有 GPU 缩放输出视图"))?;
            let source_rect = RECT { left: 0, top: 0, right: source.0 as i32, bottom: source.1 as i32 };
            let target_rect = RECT { left: 0, top: 0, right: size.0 as i32, bottom: size.1 as i32 };
            video_context.VideoProcessorSetStreamFrameFormat(&processor, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            video_context.VideoProcessorSetStreamColorSpace1(&processor, 0, source_color);
            video_context.VideoProcessorSetOutputColorSpace1(&processor, target_color);
            video_context.VideoProcessorSetStreamAutoProcessingMode(&processor, 0, false);
            video_context.VideoProcessorSetStreamSourceRect(&processor, 0, true, Some(&source_rect));
            video_context.VideoProcessorSetStreamDestRect(&processor, 0, true, Some(&target_rect));
            video_context.VideoProcessorSetOutputTargetRect(&processor, true, Some(&target_rect));
            Ok(Self {
                device: device.clone(),
                context,
                video_device,
                video_context,
                enumerator,
                processor,
                input: None,
                output,
                output_view,
                staging: None,
                size,
            })
        }
    }

    pub(super) fn convert(&mut self, source: &ID3D11Texture2D) -> Result<()> {
        unsafe {
            let input_view = match self.input.as_ref() {
                Some((texture, view)) if texture.as_raw() == source.as_raw() => view,
                _ => {
                    let mut view = None;
                    self.video_device
                        .CreateVideoProcessorInputView(
                            source,
                            &self.enumerator,
                            &D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC { ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D, ..Default::default() },
                            Some(&mut view),
                        )
                        .map_err(failed("创建 GPU 缩放输入视图"))?;
                    let view = view.ok_or_else(|| DeskError::platform("没有 GPU 缩放输入视图"))?;
                    &self.input.insert((source.clone(), view)).1
                }
            };
            let mut stream =
                D3D11_VIDEO_PROCESSOR_STREAM { Enable: true.into(), pInputSurface: ManuallyDrop::new(Some(input_view.clone())), ..Default::default() };
            let result = self.video_context.VideoProcessorBlt(&self.processor, &self.output_view, 0, std::slice::from_ref(&stream));
            ManuallyDrop::drop(&mut stream.pInputSurface);
            result.map_err(failed("GPU 缩放桌面画面"))
        }
    }

    /// The scaler reuses this surface at the next conversion. Async encoders need their own copy.
    pub(super) fn texture(&self) -> &ID3D11Texture2D {
        &self.output
    }

    pub(super) fn read_nv12(&mut self, target: &mut [u8]) -> Result<()> {
        let (width, height) = (self.size.0 as usize, self.size.1 as usize);
        let rows = height + height / 2;
        if target.len() != width * rows {
            return Err(DeskError::platform("NV12 缓冲区尺寸不符"));
        }
        if self.staging.is_none() {
            self.staging = Some(nv12_texture(&self.device, self.size, D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_READ.0 as u32)?);
        }
        let staging = self.staging.as_ref().unwrap();
        unsafe {
            self.context.CopyResource(staging, self.texture());
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context.Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)).map_err(failed("回读 GPU 缩放画面"))?;
            let pitch = mapped.RowPitch as usize;
            let result = if pitch < width || mapped.pData.is_null() {
                Err(DeskError::platform("GPU 返回的 NV12 布局无效"))
            } else {
                // D3D11 places the interleaved UV rows after all pitched luma rows.
                copy_nv12_rows(mapped.pData.cast::<u8>(), pitch, target, width);
                Ok(())
            };
            self.context.Unmap(staging, 0);
            result
        }
    }
}

fn nv12_texture(device: &ID3D11Device, size: (u32, u32), usage: D3D11_USAGE, bind: u32, cpu_access: u32) -> Result<ID3D11Texture2D> {
    unsafe {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: size.0,
            Height: size.1,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_NV12,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: usage,
            BindFlags: bind,
            CPUAccessFlags: cpu_access,
            ..Default::default()
        };
        let mut texture = None;
        device.CreateTexture2D(&desc, None, Some(&mut texture)).map_err(failed("创建 GPU 缩放纹理"))?;
        texture.ok_or_else(|| DeskError::platform("没有 GPU 缩放纹理"))
    }
}

/// `source` must have `width` readable bytes per row for each packed row in `target`.
unsafe fn copy_nv12_rows(source: *const u8, pitch: usize, target: &mut [u8], width: usize) {
    for (row, target) in target.chunks_exact_mut(width).enumerate() {
        unsafe { std::ptr::copy_nonoverlapping(source.add(row * pitch), target.as_mut_ptr(), width) };
    }
}

#[cfg(test)]
mod tests {
    use super::copy_nv12_rows;

    #[test]
    fn nv12_readback_keeps_luma_and_chroma_order_without_pitch_padding() {
        let mapped = [16, 235, 16, 235, 0, 0, 32, 219, 32, 219, 0, 0, 128, 128, 102, 240, 0, 0];
        let mut packed = [0; 12];
        unsafe { copy_nv12_rows(mapped.as_ptr(), 6, &mut packed, 4) };
        assert_eq!(packed, [16, 235, 16, 235, 32, 219, 32, 219, 128, 128, 102, 240]);
    }
}
