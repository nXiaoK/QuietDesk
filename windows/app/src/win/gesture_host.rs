//! Two-contact touchscreen replay for applications that accept Windows pointer input.

use super::inject::{contains, display_point};
use quietdesk_core::messages::{ScrollPhase, TrackpadGesture};
use std::time::Duration;
use tokio::time::Instant;
use windows::Win32::Foundation::{ERROR_NOT_READY, GetLastError, HWND, POINT, RECT};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
use windows::Win32::UI::Controls::{HSYNTHETICPOINTERDEVICE, POINTER_FEEDBACK_MODE, POINTER_FEEDBACK_NONE, POINTER_TYPE_INFO, POINTER_TYPE_INFO_0};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::Pointer::*;
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{BOOL, s, w};

type Create = unsafe extern "system" fn(POINTER_INPUT_TYPE, u32, POINTER_FEEDBACK_MODE) -> HSYNTHETICPOINTERDEVICE;
type Inject = unsafe extern "system" fn(HSYNTHETICPOINTERDEVICE, *const POINTER_TYPE_INFO, u32) -> BOOL;
type Destroy = unsafe extern "system" fn(HSYNTHETICPOINTERDEVICE);

struct TouchDevice {
    handle: isize,
    inject: Inject,
    destroy: Destroy,
}

impl TouchDevice {
    fn open() -> Option<Self> {
        // Windows 10 before 1809 can still load the app and negotiate ordinary mouse input.
        unsafe {
            let user = GetModuleHandleW(w!("user32.dll")).ok()?;
            let create: Create = std::mem::transmute(GetProcAddress(user, s!("CreateSyntheticPointerDevice"))?);
            let inject: Inject = std::mem::transmute(GetProcAddress(user, s!("InjectSyntheticPointerInput"))?);
            let destroy: Destroy = std::mem::transmute(GetProcAddress(user, s!("DestroySyntheticPointerDevice"))?);
            let handle = create(PT_TOUCH, 2, POINTER_FEEDBACK_NONE);
            if handle.is_invalid() {
                return None;
            }
            Some(Self { handle: handle.0 as isize, inject, destroy })
        }
    }

    fn frame(&self, points: [POINT; 2], origin: POINT, flags: POINTER_FLAGS) -> bool {
        let contacts = std::array::from_fn::<_, 2, _>(|i| {
            let pos = POINT { x: points[i].x - origin.x, y: points[i].y - origin.y };
            let pointer = POINTER_INFO { pointerType: PT_TOUCH, pointerId: i as u32 + 1, pointerFlags: flags, ptPixelLocation: pos, ..Default::default() };
            POINTER_TYPE_INFO {
                r#type: PT_TOUCH,
                Anonymous: POINTER_TYPE_INFO_0 { touchInfo: POINTER_TOUCH_INFO { pointerInfo: pointer, ..Default::default() } },
            }
        });
        let send = || unsafe { (self.inject)(HSYNTHETICPOINTERDEVICE(self.handle as _), contacts.as_ptr(), contacts.len() as u32).as_bool() };
        if send() {
            return true;
        }
        if unsafe { GetLastError() } == ERROR_NOT_READY {
            // Consecutive frames can fall in the same Windows input timestamp interval.
            std::thread::sleep(Duration::from_millis(1));
            if send() {
                return true;
            }
        }
        log::debug!("touch frame rejected: {:?}", unsafe { GetLastError() });
        false
    }
}

impl Drop for TouchDevice {
    fn drop(&mut self) {
        unsafe { (self.destroy)(HSYNTHETICPOINTERDEVICE(self.handle as _)) };
    }
}

fn origin() -> POINT {
    unsafe { POINT { x: GetSystemMetrics(SM_XVIRTUALSCREEN), y: GetSystemMetrics(SM_YVIRTUALSCREEN) } }
}

struct Target {
    foreground: isize,
    leaf: isize,
    display: RECT,
    origin: POINT,
    relative: bool,
}

impl Target {
    fn at(display: RECT, anchor: POINT, relative: bool) -> Option<Self> {
        unsafe {
            let leaf = WindowFromPoint(anchor);
            let foreground = GetForegroundWindow();
            if !contains(display, anchor) || leaf.is_invalid() || foreground.is_invalid() || GetAncestor(leaf, GA_ROOT) != foreground {
                return None;
            }
            Some(Self { foreground: foreground.0 as isize, leaf: leaf.0 as isize, display, origin: origin(), relative })
        }
    }

    fn receives(&self, points: [POINT; 2]) -> bool {
        if self.relative {
            let mut current = POINT::default();
            if unsafe { GetCursorPos(&mut current) }.is_err() || !contains(self.display, current) {
                return false;
            }
        }
        self.origin == origin()
            && unsafe {
                GetForegroundWindow().0 as isize == self.foreground
                    && GetAncestor(HWND(self.leaf as _), GA_ROOT).0 as isize == self.foreground
                    && points.iter().all(|&p| contains(self.display, p) && WindowFromPoint(p).0 as isize == self.leaf)
            }
    }
}

#[derive(Clone, Copy)]
struct Pose {
    anchor: POINT,
    radius: f64,
    angle: f64,
    min_radius: f64,
    max_radius: f64,
}

impl Pose {
    fn new(anchor: POINT, display: RECT, scale: f64) -> Option<Self> {
        let room = (anchor.x - display.left).min(display.right - 1 - anchor.x).min(anchor.y - display.top).min(display.bottom - 1 - anchor.y);
        let max_radius = f64::from(room);
        let min_radius = 8.0 * scale;
        let radius = (36.0 * scale).min(max_radius * 0.6);
        (radius >= min_radius).then_some(Self { anchor, radius, angle: 0.0, min_radius, max_radius })
    }

    fn points(self) -> [POINT; 2] {
        let dx = (self.radius * self.angle.cos()).round() as i32;
        let dy = (self.radius * self.angle.sin()).round() as i32;
        [POINT { x: self.anchor.x - dx, y: self.anchor.y - dy }, POINT { x: self.anchor.x + dx, y: self.anchor.y + dy }]
    }

    fn change(&mut self, gesture: TrackpadGesture) {
        match gesture {
            TrackpadGesture::Magnify(value) => self.radius = (self.radius * (1.0 + value)).clamp(self.min_radius, self.max_radius),
            TrackpadGesture::Rotate(degrees) => self.angle = (self.angle - degrees.to_radians()).rem_euclid(std::f64::consts::TAU),
            TrackpadGesture::SmartMagnify => self.radius = (self.radius * 1.6).min(self.max_radius),
        }
    }
}

struct Contacts {
    pose: Pose,
    last: Option<[POINT; 2]>,
    magnifying: bool,
    rotating: bool,
}

impl Contacts {
    fn open_phase(&mut self, gesture: TrackpadGesture) -> &mut bool {
        match gesture {
            TrackpadGesture::Rotate(_) => &mut self.rotating,
            _ => &mut self.magnifying,
        }
    }

    fn update(&mut self, gesture: TrackpadGesture, permits: impl Fn([POINT; 2]) -> bool, mut frame: impl FnMut([POINT; 2], POINTER_FLAGS) -> bool) -> bool {
        let (steps, change) = match gesture {
            TrackpadGesture::Rotate(degrees) => {
                // Two positions alone cannot distinguish adjacent turns of 180 degrees or more.
                let steps = (degrees.abs() / 90.0).ceil().max(1.0) as u32;
                (steps, TrackpadGesture::Rotate(degrees / f64::from(steps)))
            }
            _ => (1, gesture),
        };
        for _ in 0..steps {
            let previous = self.pose.points();
            self.pose.change(change);
            let next = self.pose.points();
            if next == previous {
                continue;
            }
            if !permits(next) {
                return false;
            }
            if self.last.is_none() {
                if !permits(previous) || !frame(previous, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT) {
                    return false;
                }
                self.last = Some(previous);
            }
            if !frame(next, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT) {
                return false;
            }
            self.last = Some(next);
        }
        true
    }
}

struct Session {
    target: Target,
    contacts: Contacts,
    last_event: Instant,
    next_check: Instant,
}

const CHECK_INTERVAL: Duration = Duration::from_millis(100);
const ABANDONED_CONTACT: Duration = Duration::from_secs(4);

pub(super) struct GestureHost {
    device: Option<TouchDevice>,
    session: Option<Session>,
}

impl GestureHost {
    pub(super) fn new() -> Self {
        Self { device: TouchDevice::open(), session: None }
    }

    pub(super) fn available(&self) -> bool {
        self.device.is_some()
    }

    pub(super) fn check_at(&self) -> Option<Instant> {
        self.session.as_ref().map(|s| s.next_check)
    }

    pub(super) fn check(&mut self, display: Option<RECT>) {
        if let Some(s) = &mut self.session {
            let now = Instant::now();
            if display != Some(s.target.display)
                || now.duration_since(s.last_event) >= ABANDONED_CONTACT
                || !s.target.receives(s.contacts.last.unwrap_or([s.contacts.pose.anchor; 2]))
            {
                self.cancel();
            } else {
                s.next_check = now + CHECK_INTERVAL;
            }
        }
    }

    pub(super) fn cancel(&mut self) -> bool {
        self.end(POINTER_FLAG_CANCELED | POINTER_FLAG_UP)
    }

    fn end(&mut self, flags: POINTER_FLAGS) -> bool {
        let Some(s) = self.session.take() else { return true };
        let Some(last) = s.contacts.last else { return true };
        if let Some(device) = &self.device {
            if device.frame(last, s.target.origin, flags) {
                return true;
            }
            if flags == POINTER_FLAG_UP && device.frame(last, s.target.origin, POINTER_FLAG_CANCELED | POINTER_FLAG_UP) {
                return false;
            }
        }
        // Removing the native device also retires its contacts if Windows refused their final frame.
        self.device.take();
        false
    }

    pub(super) fn gesture(&mut self, gesture: TrackpadGesture, phase: Option<ScrollPhase>, x: f64, y: f64, relative: bool, display: Option<RECT>) -> bool {
        let Some(display) = display else {
            self.cancel();
            return false;
        };
        if phase == Some(ScrollPhase::MayBegin) {
            return true;
        }
        if phase == Some(ScrollPhase::Cancelled) {
            if let Some(s) = &mut self.session {
                *s.contacts.open_phase(gesture) = false;
                if s.contacts.magnifying || s.contacts.rotating {
                    return true;
                }
            }
            return self.cancel();
        }
        let discrete = phase.is_none() || gesture == TrackpadGesture::SmartMagnify;
        if discrete && !self.cancel() {
            return false;
        }
        if self.session.is_none() {
            if !discrete && phase != Some(ScrollPhase::Began) {
                return false;
            }
            let mut anchor = display_point(display, x, y);
            if relative && unsafe { GetCursorPos(&mut anchor) }.is_err() {
                return false;
            }
            let Some(target) = Target::at(display, anchor, relative) else { return false };
            let dpi = unsafe { GetDpiForWindow(HWND(target.foreground as _)) };
            if dpi == 0 {
                return false;
            }
            let Some(pose) = Pose::new(anchor, display, f64::from(dpi) / 96.0) else { return false };
            if self.device.is_none() {
                self.device = TouchDevice::open();
            }
            if self.device.is_none() {
                return false;
            }
            let now = Instant::now();
            self.session = Some(Session {
                target,
                contacts: Contacts { pose, last: None, magnifying: false, rotating: false },
                last_event: now,
                next_check: now + CHECK_INTERVAL,
            });
        }
        let s = self.session.as_mut().unwrap();
        if s.target.display != display || s.target.relative != relative || !s.target.receives([s.contacts.pose.anchor; 2]) {
            self.cancel();
            return false;
        }
        if !discrete {
            let open = s.contacts.open_phase(gesture);
            if phase == Some(ScrollPhase::Began) {
                *open = true;
            }
            if !*open {
                return false;
            }
        }
        s.last_event = Instant::now();
        let device = self.device.as_ref().unwrap();
        let target = &s.target;
        let accepted = s.contacts.update(gesture, |points| target.receives(points), |points, flags| device.frame(points, target.origin, flags));
        if !accepted {
            self.cancel();
            return false;
        }
        if phase == Some(ScrollPhase::Ended) {
            *s.contacts.open_phase(gesture) = false;
        }
        if !s.contacts.magnifying && !s.contacts.rotating {
            return self.end(POINTER_FLAG_UP);
        }
        true
    }
}

impl Drop for GestureHost {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: RECT = RECT { left: -1280, top: -128, right: 0, bottom: 896 };
    const ANCHOR: POINT = POINT { x: -960, y: 64 };

    fn contacts() -> Contacts {
        Contacts { pose: Pose::new(ANCHOR, SCREEN, 1.0).unwrap(), last: None, magnifying: false, rotating: false }
    }

    #[test]
    fn pinch_and_smart_zoom_spread_two_points_around_the_anchor() {
        for gesture in [TrackpadGesture::Magnify(0.5), TrackpadGesture::SmartMagnify] {
            let mut sequence = contacts();
            let mut frames = Vec::new();
            assert!(sequence.update(
                gesture,
                |_| true,
                |pos, flags| {
                    frames.push((pos, flags));
                    true
                }
            ));
            assert_eq!(frames.len(), 2);
            assert!(frames[0].1.contains(POINTER_FLAG_DOWN) && frames[1].1.contains(POINTER_FLAG_UPDATE));
            let (first, last) = (frames[0].0, frames[1].0);
            assert!(last[0].x < first[0].x && last[1].x > first[1].x);
            assert_eq!((last[0].x + last[1].x, last[0].y + last[1].y), (2 * ANCHOR.x, 2 * ANCHOR.y));
        }
    }

    #[test]
    fn positive_rotation_is_counterclockwise_and_preserves_large_angles() {
        let mut sequence = contacts();
        let mut steps = Vec::new();
        assert!(sequence.update(
            TrackpadGesture::Rotate(360.0),
            |_| true,
            |p, _| {
                steps.push(p);
                true
            }
        ));
        assert_eq!(steps.len(), 5);
        assert_eq!(steps[1][1], POINT { x: ANCHOR.x, y: ANCHOR.y - 36 });
        assert_eq!(steps[2][1], steps[0][0]);
        assert_eq!(steps[4], steps[0]);
    }

    #[test]
    fn clipped_or_stationary_gestures_do_not_start_a_contact() {
        assert!(Pose::new(POINT { x: SCREEN.left, y: ANCHOR.y }, SCREEN, 2.0).is_none());
        let mut sequence = contacts();
        assert!(sequence.update(TrackpadGesture::Magnify(0.0), |_| true, |_, _| panic!("stationary touch down")));
        assert!(!sequence.update(TrackpadGesture::SmartMagnify, |_| false, |_, _| panic!("contact outside the target")));
        assert!(sequence.last.is_none());
    }

    #[derive(Default)]
    struct Recorder {
        frames: Vec<[(u32, POINT, POINTER_FLAGS); 2]>,
        reject_release: bool,
        destroyed: bool,
    }

    unsafe extern "system" fn record(handle: HSYNTHETICPOINTERDEVICE, info: *const POINTER_TYPE_INFO, count: u32) -> BOOL {
        let target = unsafe { &mut *handle.0.cast::<Recorder>() };
        if count != 2 {
            return false.into();
        }
        let pair = std::array::from_fn(|i| {
            let p = unsafe { (*info.add(i)).Anonymous.touchInfo.pointerInfo };
            (p.pointerId, p.ptPixelLocation, p.pointerFlags)
        });
        target.frames.push(pair);
        (!target.reject_release).into()
    }

    unsafe extern "system" fn destroy(handle: HSYNTHETICPOINTERDEVICE) {
        unsafe { (*handle.0.cast::<Recorder>()).destroyed = true };
    }

    fn mock_device(recorder: &mut Recorder) -> TouchDevice {
        TouchDevice { handle: std::ptr::from_mut(recorder) as isize, inject: record, destroy }
    }

    fn session_with_contact() -> Session {
        let mut contacts = contacts();
        assert!(!contacts.update(TrackpadGesture::Magnify(0.5), |_| true, |_, flags| flags.contains(POINTER_FLAG_DOWN)));
        let target = Target { foreground: 0, leaf: 0, display: SCREEN, origin: POINT { x: SCREEN.left, y: SCREEN.top }, relative: false };
        let now = Instant::now();
        Session { target, contacts, last_event: now, next_check: now }
    }

    #[test]
    fn loss_of_display_cancels_both_ids_at_the_last_accepted_virtual_coordinates() {
        let mut recorder = Recorder::default();
        let mut host = GestureHost { device: Some(mock_device(&mut recorder)), session: Some(session_with_contact()) };
        host.check(None);
        assert!(host.check_at().is_none());
        assert_eq!(
            recorder.frames,
            [[(1, POINT { x: 284, y: 192 }, POINTER_FLAG_CANCELED | POINTER_FLAG_UP), (2, POINT { x: 356, y: 192 }, POINTER_FLAG_CANCELED | POINTER_FLAG_UP),]]
        );
        assert!(!host.gesture(TrackpadGesture::Magnify(0.1), Some(ScrollPhase::Changed), 0.5, 0.5, false, Some(SCREEN)));
    }

    #[test]
    fn failed_cancel_disposes_the_injection_device() {
        let mut recorder = Recorder { reject_release: true, ..Default::default() };
        let mut host = GestureHost { device: Some(mock_device(&mut recorder)), session: Some(session_with_contact()) };
        assert!(!host.cancel());
        assert!(recorder.destroyed && !host.available());
    }

    #[test]
    fn cancelling_rotation_preserves_a_simultaneous_pinch_until_it_ends() {
        let mut recorder = Recorder::default();
        let mut session = session_with_contact();
        session.contacts.magnifying = true;
        session.contacts.rotating = true;
        let mut host = GestureHost { device: Some(mock_device(&mut recorder)), session: Some(session) };
        assert!(host.gesture(TrackpadGesture::Rotate(0.0), Some(ScrollPhase::Cancelled), 0.5, 0.5, false, Some(SCREEN)));
        assert!(recorder.frames.is_empty() && host.check_at().is_some());
        assert!(host.gesture(TrackpadGesture::Magnify(0.0), Some(ScrollPhase::Cancelled), 0.5, 0.5, false, Some(SCREEN)));
        assert_eq!(recorder.frames.len(), 1);
        assert!(host.check_at().is_none());
    }
}
