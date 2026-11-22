use quietdesk_core::input::ViewerInputTranslator;
use quietdesk_core::messages::{MomentumPhase, RemoteInput, ScrollPhase, TrackpadGesture};
use std::time::{Duration, Instant};
use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::DirectManipulation::*;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::UI::Input::Pointer::GetPointerType;
use windows::Win32::UI::Input::Touch::*;
use windows::Win32::UI::WindowsAndMessaging::{GF_BEGIN, GF_END, GetClientRect, PT_TOUCHPAD};
use windows::core::Result;

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Motion {
    Scroll(f64, f64, Option<ScrollPhase>, Option<MomentumPhase>),
    Gesture(TrackpadGesture, ScrollPhase),
}

impl Motion {
    pub(super) fn input(self, keys: &ViewerInputTranslator, (x, y): (f64, f64)) -> Option<RemoteInput> {
        match self {
            Self::Scroll(dx, dy, phase, momentum) => keys.precise_scroll(dx, dy, phase, momentum, x, y),
            Self::Gesture(gesture, phase) => keys.gesture(gesture, Some(phase), x, y),
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Pan,
    Inertia,
    Pinch,
}

#[derive(Default)]
struct Manipulation {
    mode: Option<Mode>,
    previous: Option<[f32; 6]>,
}

impl Manipulation {
    fn finish(&mut self, output: &mut Vec<Motion>) {
        match self.mode.take() {
            Some(Mode::Pan) => output.push(Motion::Scroll(0., 0., Some(ScrollPhase::Ended), None)),
            Some(Mode::Inertia) => output.push(Motion::Scroll(0., 0., None, Some(MomentumPhase::Ended))),
            Some(Mode::Pinch) => output.push(Motion::Gesture(TrackpadGesture::Magnify(0.), ScrollPhase::Ended)),
            None => {}
        }
    }

    fn sample(&mut self, matrix: [f32; 6], inertia: bool, dpi: u32, output: &mut Vec<Motion>) {
        if !matrix.iter().all(|x| x.is_finite()) || matrix[0] <= 0. {
            return;
        }
        let old = self.previous.replace(matrix).unwrap_or([1., 0., 0., 1., 0., 0.]);
        let zoom = f64::from(matrix[0]) / f64::from(old[0]) - 1.;
        let units = 96. / f64::from(dpi.max(1));
        let (x, y) = (f64::from(matrix[4] - old[4]) * units, f64::from(matrix[5] - old[5]) * units);
        if zoom.abs() > 1e-5 || self.mode == Some(Mode::Pinch) {
            if zoom.abs() <= 1e-5 || inertia {
                return;
            }
            let starting = self.mode != Some(Mode::Pinch);
            if starting {
                self.finish(output);
            }
            self.mode = Some(Mode::Pinch);
            output.push(Motion::Gesture(TrackpadGesture::Magnify(zoom), if starting { ScrollPhase::Began } else { ScrollPhase::Changed }));
            return;
        }
        let next = if inertia { Mode::Inertia } else { Mode::Pan };
        if x == 0. && y == 0. && !(inertia && self.mode == Some(Mode::Pan)) {
            return;
        }
        let starting = self.mode != Some(next);
        if starting {
            self.finish(output);
        }
        self.mode = Some(next);
        output.push(if inertia {
            Motion::Scroll(x, y, None, Some(if starting { MomentumPhase::Began } else { MomentumPhase::Changed }))
        } else {
            Motion::Scroll(x, y, Some(if starting { ScrollPhase::Began } else { ScrollPhase::Changed }), None)
        });
    }
}

pub(super) struct Touchpad {
    window: HWND,
    manager: IDirectManipulationManager,
    updates: IDirectManipulationUpdateManager,
    viewport: IDirectManipulationViewport,
    content: IDirectManipulationContent,
    state: Manipulation,
    contact: Option<Instant>,
    pub(super) anchor: (f64, f64),
}

impl Touchpad {
    pub(super) fn open(window: HWND, gestures: bool) -> Result<Self> {
        unsafe {
            let manager: IDirectManipulationManager = CoCreateInstance(&DirectManipulationManager, None, CLSCTX_INPROC_SERVER)?;
            let updates = manager.GetUpdateManager()?;
            let viewport: IDirectManipulationViewport = manager.CreateViewport(None, window)?;
            let content = viewport.GetPrimaryContent().inspect_err(|_| {
                let _ = viewport.Abandon();
            })?;
            let pad = Self { window, manager, updates, viewport, content, state: Manipulation::default(), contact: None, anchor: (0.5, 0.5) };
            let mut config = DIRECTMANIPULATION_CONFIGURATION_INTERACTION
                | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_X
                | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y
                | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA;
            if gestures {
                config |= DIRECTMANIPULATION_CONFIGURATION_SCALING;
            }
            pad.viewport.ActivateConfiguration(config)?;
            pad.viewport.SetViewportOptions(DIRECTMANIPULATION_VIEWPORT_OPTIONS_MANUALUPDATE)?;
            pad.resize()?;
            pad.manager.Activate(window)?;
            pad.viewport.Enable()?;
            Ok(pad)
        }
    }

    pub(super) fn resize(&self) -> Result<()> {
        let mut rect = RECT::default();
        unsafe {
            GetClientRect(self.window, &mut rect)?;
            self.viewport.SetViewportRect(&rect)
        }
    }

    pub(super) fn hit(&mut self, pointer: u32, anchor: (f64, f64)) -> bool {
        let mut device = Default::default();
        unsafe {
            if GetPointerType(pointer, &mut device).is_err() || device != PT_TOUCHPAD {
                return false;
            }
            if self.viewport.SetContact(pointer).is_err() {
                return false;
            }
        }
        if self.contact.is_none() {
            self.contact = Some(Instant::now());
            self.anchor = anchor;
        }
        true
    }

    pub(super) fn poll(&mut self, dpi: u32) -> Result<(Vec<Motion>, bool)> {
        let mut output = Vec::new();
        let Some(started) = self.contact else { return Ok((output, false)) };
        unsafe {
            self.updates.Update(None)?;
            let status = self.viewport.GetStatus()?;
            let mut matrix = [0.; 6];
            self.content.GetContentTransform(&mut matrix)?;
            let inertia = status == DIRECTMANIPULATION_INERTIA || (status != DIRECTMANIPULATION_RUNNING && self.state.mode == Some(Mode::Inertia));
            self.state.sample(matrix, inertia, dpi, &mut output);
            // READY may precede the first manipulation frame or follow its final delta.
            let wait = status == DIRECTMANIPULATION_RUNNING
                || status == DIRECTMANIPULATION_INERTIA
                || (self.state.mode.is_none() && started.elapsed() < Duration::from_millis(500));
            if !wait {
                self.state.finish(&mut output);
                self.reset();
            }
            Ok((output, wait))
        }
    }

    pub(super) fn reset(&mut self) {
        if self.contact.take().is_none() {
            return;
        }
        self.state = Manipulation::default();
        let mut rect = RECT::default();
        unsafe {
            let _ = self.viewport.ReleaseAllContacts();
            let _ = self.viewport.Stop();
            if GetClientRect(self.window, &mut rect).is_ok() && rect.right > 0 && rect.bottom > 0 {
                let _ = self.viewport.ZoomToRect(0., 0., rect.right as f32, rect.bottom as f32, false);
                let _ = self.updates.Update(None);
            }
        }
    }

    pub(super) fn active(&self) -> bool {
        self.contact.is_some()
    }
}

impl Drop for Touchpad {
    fn drop(&mut self) {
        unsafe {
            let _ = self.viewport.Abandon();
            let _ = self.manager.Deactivate(self.window);
        }
    }
}

#[derive(Default)]
pub(super) struct TouchGestures {
    distance: Option<f64>,
    angle: Option<f64>,
}

impl TouchGestures {
    pub(super) fn active(&self) -> bool {
        self.distance.is_some() || self.angle.is_some()
    }
    pub(super) fn configure(window: HWND) {
        let config = [GID_ZOOM, GID_ROTATE, GID_TWOFINGERTAP].map(|id| GESTURECONFIG { dwID: id, dwWant: 1, dwBlock: 0 });
        let _ = unsafe { SetGestureConfig(window, 0, &config, size_of::<GESTURECONFIG>() as u32) };
    }

    pub(super) fn read(&mut self, handle: HGESTUREINFO) -> Option<(Motion, POINT)> {
        let mut event = GESTUREINFO { cbSize: size_of::<GESTUREINFO>() as u32, ..Default::default() };
        unsafe {
            GetGestureInfo(handle, &mut event).ok()?;
        }
        let motion = self.decode(&event)?;
        let _ = unsafe { CloseGestureInfoHandle(handle) };
        Some((motion, POINT { x: event.ptsLocation.x.into(), y: event.ptsLocation.y.into() }))
    }

    fn decode(&mut self, event: &GESTUREINFO) -> Option<Motion> {
        let phase = if event.dwFlags & GF_END != 0 {
            ScrollPhase::Ended
        } else if event.dwFlags & GF_BEGIN != 0 {
            ScrollPhase::Began
        } else {
            ScrollPhase::Changed
        };
        let gesture = match GESTURECONFIG_ID(event.dwID) {
            GID_ZOOM => {
                let distance = f64::from(event.ullArguments as u32);
                let previous = self.distance.replace(distance).filter(|d| *d > 0.);
                let delta = if phase == ScrollPhase::Began || distance <= 0. { 0. } else { previous.map_or(0., |d| distance / d - 1.) };
                if phase == ScrollPhase::Ended {
                    self.distance = None;
                }
                TrackpadGesture::Magnify(delta)
            }
            GID_ROTATE => {
                // Windows reports cumulative rotation after the initial contact orientation.
                let angle = f64::from(event.ullArguments as u16) * 720. / 65535. - 360.;
                let delta = if phase == ScrollPhase::Began {
                    self.angle = Some(0.);
                    0.
                } else {
                    let previous = self.angle.replace(angle).unwrap_or(angle);
                    (angle - previous + 180.).rem_euclid(360.) - 180.
                };
                if phase == ScrollPhase::Ended {
                    self.angle = None;
                }
                TrackpadGesture::Rotate(delta)
            }
            GID_TWOFINGERTAP => TrackpadGesture::SmartMagnify,
            _ => return None,
        };
        let phase = if gesture == TrackpadGesture::SmartMagnify { ScrollPhase::Ended } else { phase };
        Some(Motion::Gesture(gesture, phase))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn touch_messages_use_incremental_values_and_delegate_generic_handles() {
        let mut touch = TouchGestures::default();
        let mut decode =
            |id: GESTURECONFIG_ID, flags, value| touch.decode(&GESTUREINFO { dwID: id.0, dwFlags: flags, ullArguments: value, ..Default::default() });
        assert_eq!(decode(GID_BEGIN, GF_BEGIN, 0), None);
        assert_eq!(decode(GID_ZOOM, GF_BEGIN, 100), Some(Motion::Gesture(TrackpadGesture::Magnify(0.), ScrollPhase::Began)));
        assert_eq!(decode(GID_ZOOM, 0, 125), Some(Motion::Gesture(TrackpadGesture::Magnify(0.25), ScrollPhase::Changed)));
        assert_eq!(decode(GID_ZOOM, GF_END, 125), Some(Motion::Gesture(TrackpadGesture::Magnify(0.), ScrollPhase::Ended)));
        let angle = |degrees: f64| ((degrees + 360.) * 65535. / 720.).round() as u64;
        assert_eq!(decode(GID_ROTATE, GF_BEGIN, angle(-77.)), Some(Motion::Gesture(TrackpadGesture::Rotate(0.), ScrollPhase::Began)));
        for (absolute, delta, flags) in [(35., 35., 0), (47., 12., 0), (45., -2., GF_END)] {
            let Some(Motion::Gesture(TrackpadGesture::Rotate(actual), _)) = decode(GID_ROTATE, flags, angle(absolute)) else { panic!("missing rotation") };
            assert!((actual - delta).abs() < 0.02);
        }
        assert_eq!(decode(GID_TWOFINGERTAP, 0, 80), Some(Motion::Gesture(TrackpadGesture::SmartMagnify, ScrollPhase::Ended)));
        assert_eq!(decode(GID_END, GF_END, 0), None);
        assert!(!touch.active());
    }
    #[test]
    fn pan_finishes_before_inertia_and_pinch_suppresses_translation() {
        let mut state = Manipulation::default();
        let mut events = Vec::new();
        state.sample([1., 0., 0., 1., 0.5, -1.], false, 192, &mut events);
        state.sample([1., 0., 0., 1., 1., -2.], true, 192, &mut events);
        state.sample([1.25, 0., 0., 1.25, 18., 5.], false, 192, &mut events);
        state.finish(&mut events);
        assert_eq!(
            events,
            [
                Motion::Scroll(0.25, -0.5, Some(ScrollPhase::Began), None),
                Motion::Scroll(0., 0., Some(ScrollPhase::Ended), None),
                Motion::Scroll(0.25, -0.5, None, Some(MomentumPhase::Began)),
                Motion::Scroll(0., 0., None, Some(MomentumPhase::Ended)),
                Motion::Gesture(TrackpadGesture::Magnify(0.25), ScrollPhase::Began),
                Motion::Gesture(TrackpadGesture::Magnify(0.), ScrollPhase::Ended),
            ]
        );
    }
}
