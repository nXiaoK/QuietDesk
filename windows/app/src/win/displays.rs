//! Active, independently addressable Windows desktop outputs.

use super::util::from_wide;
use quietdesk_core::display::{MAX_DISPLAY_DIMENSION, MAX_DISPLAYS, MIN_DISPLAY_DIMENSION, RemoteDisplayInfo};
use quietdesk_core::error::{DeskError, Result};
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::WindowsAndMessaging::{EDD_GET_DEVICE_INTERFACE_NAME, MONITORINFOF_PRIMARY};
use windows::core::{BOOL, PCWSTR};

#[derive(Clone)]
pub(super) struct Display {
    pub info: RemoteDisplayInfo,
    pub bounds: RECT,
    monitor: isize,
    device: [u16; 32],
}

impl Display {
    pub(super) fn monitor(&self) -> HMONITOR {
        HMONITOR(self.monitor as _)
    }

    pub(super) fn same_surface(&self, other: &Self) -> bool {
        self.info.id == other.info.id && self.bounds == other.bounds && self.device == other.device && self.monitor == other.monitor
    }

    pub(super) fn still_at_bounds(&self) -> bool {
        monitor_info(self.monitor()).is_some_and(|current| current.monitorInfo.rcMonitor == self.bounds && current.szDevice == self.device)
    }
}

fn monitor_info(monitor: HMONITOR) -> Option<MONITORINFOEXW> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    unsafe { GetMonitorInfoW(monitor, &mut info.monitorInfo) }.as_bool().then_some(info)
}

// FNV-1a provides the same wire ID across launches, including after the desktop origin moves.
fn display_id(device_path: &str) -> u32 {
    device_path.bytes().fold(2_166_136_261u32, |hash, b| (hash ^ u32::from(b.to_ascii_uppercase())).wrapping_mul(16_777_619)).max(1)
}

fn monitor_device(source: &[u16; 32]) -> Option<DISPLAY_DEVICEW> {
    for index in 0.. {
        let mut device = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
        if !unsafe { EnumDisplayDevicesW(PCWSTR(source.as_ptr()), index, &mut device, EDD_GET_DEVICE_INTERFACE_NAME) }.as_bool() {
            break;
        }
        if device.StateFlags.contains(DISPLAY_DEVICE_ACTIVE) {
            return Some(device);
        }
    }
    None
}

pub(super) fn outputs() -> Result<Vec<Display>> {
    unsafe extern "system" fn collect(monitor: HMONITOR, _: HDC, _: *mut RECT, context: LPARAM) -> BOOL {
        let monitors = unsafe { &mut *(context.0 as *mut Vec<HMONITOR>) };
        monitors.push(monitor);
        true.into()
    }
    let mut monitors: Vec<HMONITOR> = Vec::new();
    let context = LPARAM(std::ptr::from_mut(&mut monitors) as isize);
    unsafe { EnumDisplayMonitors(None, None, Some(collect), context) }.ok().map_err(super::util::failed("枚举显示器"))?;
    let mut displays = Vec::new();
    for monitor in monitors {
        let Some(source) = monitor_info(monitor) else { continue };
        let bounds = source.monitorInfo.rcMonitor;
        let (width, height) = (bounds.right - bounds.left, bounds.bottom - bounds.top);
        if width <= 0 || height <= 0 {
            continue;
        }
        let device = monitor_device(&source.szDevice).unwrap_or_default();
        let device_name = from_wide(&source.szDevice);
        let interface = from_wide(&device.DeviceID);
        let label = from_wide(&device.DeviceString);
        let id = display_id(if interface.is_empty() { &device_name } else { &interface });
        let name = if label.trim().is_empty() { device_name.trim_start_matches(r"\\.\").to_owned() } else { label };
        let info = RemoteDisplayInfo::new(
            id,
            &name,
            (width as u32).clamp(MIN_DISPLAY_DIMENSION, MAX_DISPLAY_DIMENSION),
            (height as u32).clamp(MIN_DISPLAY_DIMENSION, MAX_DISPLAY_DIMENSION),
            source.monitorInfo.dwFlags & MONITORINFOF_PRIMARY != 0,
        );
        displays.push(Display { info, bounds, monitor: monitor.0 as isize, device: source.szDevice });
    }
    displays.sort_by_key(|d| (!d.info.is_main, d.info.id));
    if displays.is_empty() {
        return Err(DeskError::platform("没有找到活动显示器"));
    }
    let mut ids = std::collections::BTreeSet::new();
    if displays.iter().any(|d| !ids.insert(d.info.id)) {
        return Err(DeskError::platform("显示器设备标识冲突"));
    }
    Ok(displays)
}

pub fn available(selected: Option<u32>) -> Result<Vec<RemoteDisplayInfo>> {
    Ok(directory(outputs()?, selected))
}

pub(super) fn directory(displays: Vec<Display>, selected: Option<u32>) -> Vec<RemoteDisplayInfo> {
    let mut infos: Vec<_> = displays.into_iter().map(|display| display.info).collect();
    if let Some(index) = infos.iter().position(|d| Some(d.id) == selected)
        && index >= MAX_DISPLAYS
    {
        infos.swap(MAX_DISPLAYS - 1, index);
    }
    infos.truncate(MAX_DISPLAYS);
    infos
}

pub(super) fn preferred(displays: &[Display], id: Option<u32>) -> &Display {
    displays.iter().find(|d| Some(d.info.id) == id).unwrap_or(&displays[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn external(id: u32) -> Display {
        Display {
            info: RemoteDisplayInfo::new(id, "External", 1920, 1080, false),
            bounds: RECT { left: -1920, top: 0, right: 0, bottom: 1080 },
            monitor: 1,
            device: [0; 32],
        }
    }

    #[test]
    fn device_interface_ids_survive_case_changes_and_distinguish_outputs() {
        assert_eq!(display_id("Monitor#Dell#A"), display_id("MONITOR#DELL#A"));
        assert_ne!(display_id("Monitor#Dell#A"), display_id("Monitor#Dell#B"));
        assert_ne!(display_id("Monitor#Dell#A"), 0);
    }

    #[test]
    fn repositioning_a_display_invalidates_capture_even_at_the_same_pixel_size() {
        let original = external(7);
        let mut moved = original.clone();
        assert!(original.same_surface(&moved));
        moved.bounds = RECT { left: 0, top: -1080, right: 1920, bottom: 0 };
        assert!(!original.same_surface(&moved));
    }

    #[test]
    fn an_extra_output_does_not_displace_the_screen_already_being_shared() {
        let selected = MAX_DISPLAYS as u32 + 1;
        let advertised = directory((1..=selected).map(external).collect(), Some(selected));
        assert_eq!(advertised.len(), MAX_DISPLAYS);
        assert_eq!(advertised.first().unwrap().id, 1);
        assert_eq!(advertised.last().unwrap().id, selected);
    }
}
