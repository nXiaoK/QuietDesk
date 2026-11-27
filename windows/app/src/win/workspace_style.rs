//! Palette and owner drawing for the native workspace controls.

use windows::Win32::Foundation::{COLORREF, POINT, RECT, SIZE};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::UI::Accessibility::{HCF_HIGHCONTRASTON, HIGHCONTRASTW};
use windows::Win32::UI::Controls::{DRAWITEMSTRUCT, ODS_DISABLED, ODS_FLAGS, ODS_FOCUS, ODS_HOTLIGHT, ODS_NOFOCUSRECT, ODS_SELECTED};
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowTextLengthW, GetWindowTextW, SPI_GETHIGHCONTRAST, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SystemParametersInfoW,
};
use windows::core::{PCWSTR, w};

#[derive(Clone, Copy)]
pub(super) enum Surface {
    Canvas,
    Sidebar,
    Card,
    Inset,
    Hairline,
    Preview,
    Selection,
}

#[derive(Clone, Copy)]
pub(super) enum TextTone {
    Ink,
    Secondary,
    Muted,
    Emerald,
    Amber,
    Accent,
}

#[derive(Clone, Copy)]
pub(super) enum FontRole {
    Body,
    Emphasis,
    PageTitle,
    SectionTitle,
    Small,
    Code,
}

#[derive(Clone, Copy)]
pub(super) enum NavigationIcon {
    Devices,
    Sharing,
    Settings,
    Add,
    Computer,
    Network,
    Options,
    Ready,
}

#[derive(Clone, Copy)]
pub(super) enum ButtonKind {
    Primary,
    Secondary,
    SidebarAction,
    Danger,
    Navigation { selected: bool, icon: Option<NavigationIcon> },
    Tab { selected: bool },
    Tool { selected: bool, icon: Option<NavigationIcon> },
}

struct Palette {
    high_contrast: bool,
    surfaces: [COLORREF; 7],
    text: [COLORREF; 6],
    selection_text: COLORREF,
    hot: COLORREF,
    primary: COLORREF,
    primary_pressed: COLORREF,
    primary_text: COLORREF,
    danger: COLORREF,
    danger_fill: COLORREF,
    danger_hot: COLORREF,
    disabled: COLORREF,
    disabled_fill: COLORREF,
}

impl Palette {
    fn system() -> Self {
        let mut contrast = HIGHCONTRASTW { cbSize: size_of::<HIGHCONTRASTW>() as u32, ..Default::default() };
        let high_contrast = unsafe {
            SystemParametersInfoW(SPI_GETHIGHCONTRAST, contrast.cbSize, Some(std::ptr::from_mut(&mut contrast).cast()), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0))
                .is_ok()
                && contrast.dwFlags.contains(HCF_HIGHCONTRASTON)
        };
        if high_contrast {
            let system = |index| COLORREF(unsafe { GetSysColor(index) });
            let background = system(COLOR_WINDOW);
            let foreground = system(COLOR_WINDOWTEXT);
            let highlight = system(COLOR_HIGHLIGHT);
            let highlight_text = system(COLOR_HIGHLIGHTTEXT);
            return Self {
                high_contrast,
                surfaces: [background, background, background, background, foreground, background, highlight],
                text: [foreground; 6],
                selection_text: highlight_text,
                hot: highlight,
                primary: highlight,
                primary_pressed: foreground,
                primary_text: highlight_text,
                danger: foreground,
                danger_fill: background,
                danger_hot: highlight,
                disabled: system(COLOR_GRAYTEXT),
                disabled_fill: background,
            };
        }

        Self {
            high_contrast,
            surfaces: [rgb(0xFBFCFE), rgb(0xF3F6FA), rgb(0xFFFFFF), rgb(0xF3F6FA), rgb(0xDDE5EF), rgb(0xF6F8FD), rgb(0xEAF1FF)],
            text: [rgb(0x1C2839), rgb(0x55647A), rgb(0x63738A), rgb(0x286047), rgb(0x805015), rgb(0x2454B5)],
            selection_text: rgb(0x182F61),
            hot: rgb(0xE8EFFB),
            primary: rgb(0x285DD6),
            primary_pressed: rgb(0x1E4CBA),
            primary_text: rgb(0xFFFFFF),
            danger: rgb(0xA23C34),
            danger_fill: rgb(0xF8E7E2),
            danger_hot: rgb(0xF4D8D2),
            disabled: rgb(0x63738A),
            disabled_fill: rgb(0xF1F3F7),
        }
    }
}

pub(super) struct Theme {
    dpi: u32,
    fonts: [HFONT; 6],
    palette: Palette,
    brushes: [HBRUSH; 7],
}

impl Theme {
    pub(super) fn new(dpi: u32) -> Self {
        let font = |height, weight: FONT_WEIGHT, family: PCWSTR| unsafe {
            CreateFontW(
                -scale(dpi, height),
                0,
                0,
                0,
                weight.0 as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY,
                0,
                family,
            )
        };
        let fonts = [
            font(14, FW_NORMAL, w!("Segoe UI")),
            font(14, FW_SEMIBOLD, w!("Segoe UI")),
            font(26, FW_BOLD, w!("Segoe UI")),
            font(16, FW_SEMIBOLD, w!("Segoe UI")),
            font(12, FW_NORMAL, w!("Segoe UI")),
            font(18, FW_SEMIBOLD, w!("Consolas")),
        ];
        let palette = Palette::system();
        let brushes = palette.surfaces.map(|color| unsafe { CreateSolidBrush(color) });
        Self { dpi, fonts, palette, brushes }
    }

    pub(super) fn refresh_palette(&mut self) {
        let palette = Palette::system();
        let brushes = palette.surfaces.map(|color| unsafe { CreateSolidBrush(color) });
        for brush in std::mem::replace(&mut self.brushes, brushes) {
            let _ = unsafe { DeleteObject(brush.into()) };
        }
        self.palette = palette;
    }

    pub(super) fn scale(&self, value: i32) -> i32 {
        scale(self.dpi, value)
    }

    pub(super) fn font(&self, role: FontRole) -> HFONT {
        let font = self.fonts[role as usize];
        if font.is_invalid() { HFONT(unsafe { GetStockObject(DEFAULT_GUI_FONT) }.0) } else { font }
    }

    pub(super) fn color(&self, tone: TextTone) -> COLORREF {
        self.palette.text[tone as usize]
    }

    pub(super) fn surface_color(&self, surface: Surface) -> COLORREF {
        self.palette.surfaces[surface as usize]
    }

    pub(super) fn fill(&self, dc: HDC, rect: &RECT, surface: Surface) {
        unsafe { FillRect(dc, rect, self.brushes[surface as usize]) };
    }

    pub(super) fn card(&self, dc: HDC, rect: &RECT) {
        round_box(dc, rect, self.scale(20), self.surface_color(Surface::Card), self.surface_color(Surface::Hairline));
    }

    pub(super) fn app_mark(&self, dc: HDC, x: i32, y: i32) {
        let color = if self.palette.high_contrast { self.color(TextTone::Ink) } else { self.palette.primary };
        unsafe {
            let saved = SaveDC(dc);
            SelectObject(dc, GetStockObject(DC_PEN));
            SelectObject(dc, GetStockObject(NULL_BRUSH));
            SetDCPenColor(dc, color);
            for offset in [0, self.scale(6)] {
                let size = self.scale(14);
                let radius = self.scale(5);
                let (left, top) = (x + offset, y + offset);
                let _ = RoundRect(dc, left, top, left + size, top + size, radius, radius);
            }
            let _ = RestoreDC(dc, saved);
        }
    }

    pub(super) fn sharing_indicator(&self, dc: HDC, x: i32, y: i32, active: bool) {
        let color = if active && !self.palette.high_contrast { rgb(0x328354) } else { self.color(TextTone::Muted) };
        self.dot(dc, x, y, self.scale(7), color);
    }

    pub(super) fn device_preview(&self, dc: HDC, rect: &RECT) {
        let bounds = |left, top, right, bottom| RECT { left, top, right, bottom };
        let preview = self.surface_color(Surface::Preview);
        round_box(dc, rect, self.scale(16), preview, self.surface_color(Surface::Hairline));

        let margin = self.scale(12);
        let step = self.scale(19).max(1) as usize;
        if !self.palette.high_contrast {
            for y in (rect.top + margin..rect.bottom - margin).step_by(step) {
                for x in (rect.left + margin..rect.right - margin).step_by(step) {
                    let _ = unsafe { SetPixelV(dc, x, y, rgb(0xCBDCF7)) };
                }
            }
        }

        if rect.right - rect.left < self.scale(174) || rect.bottom - rect.top < self.scale(128) {
            return;
        }

        let mid_x = (rect.left + rect.right) / 2;
        let mid_y = (rect.top + rect.bottom) / 2 - self.scale(25);
        let x = |n| mid_x + self.scale(n);
        let y = |n| mid_y + self.scale(n);
        let stroke = if self.palette.high_contrast { self.color(TextTone::Ink) } else { rgb(0x91B4EC) };
        let glass = if self.palette.high_contrast { preview } else { rgb(0xFBFCFF) };
        for window in [bounds(x(-78), y(-43), x(18), y(19)), bounds(x(-13), y(-13), x(79), y(47))] {
            round_box(dc, &window, self.scale(18), glass, stroke);
            for offset in [12, 20, 28] {
                self.dot(dc, window.left + self.scale(offset), window.top + self.scale(10), self.scale(4), stroke);
            }
        }
        self.dot(dc, x(-13), y(19), self.scale(7), self.palette.primary);
    }

    fn dot(&self, dc: HDC, x: i32, y: i32, size: i32, color: COLORREF) {
        unsafe {
            let saved = SaveDC(dc);
            SelectObject(dc, GetStockObject(NULL_PEN));
            SelectObject(dc, GetStockObject(DC_BRUSH));
            SetDCBrushColor(dc, color);
            let left = x - size / 2;
            let top = y - size / 2;
            let _ = Ellipse(dc, left, top, left + size, top + size);
            let _ = RestoreDC(dc, saved);
        }
    }

    pub(super) fn control_colors(&self, dc: HDC, surface: Surface, tone: TextTone) -> HBRUSH {
        let color = if self.palette.high_contrast && matches!(surface, Surface::Selection) { self.palette.selection_text } else { self.color(tone) };
        unsafe {
            SetTextColor(dc, color);
            SetBkColor(dc, self.surface_color(surface));
            SetBkMode(dc, OPAQUE);
        }
        self.brushes[surface as usize]
    }

    pub(super) fn draw_button(&self, item: &DRAWITEMSTRUCT, kind: ButtonKind) {
        let length = unsafe { GetWindowTextLengthW(item.hwndItem) } as usize;
        let mut label = vec![0; length + 1];
        let length = unsafe { GetWindowTextW(item.hwndItem, &mut label) } as usize;
        self.paint_item(item, &mut label[..length], kind);
    }

    pub(super) fn draw_device(&self, item: &DRAWITEMSTRUCT, label: &str) {
        if item.itemID == u32::MAX {
            self.fill(item.hDC, &item.rcItem, Surface::Sidebar);
            return;
        }
        let mut label: Vec<u16> = label.encode_utf16().collect();
        self.paint_item(item, &mut label, ButtonKind::Navigation { selected: false, icon: Some(NavigationIcon::Computer) });
    }

    fn paint_item(&self, item: &DRAWITEMSTRUCT, label: &mut [u16], kind: ButtonKind) {
        let dc = item.hDC;
        let palette = &self.palette;
        let has_state = |flag: ODS_FLAGS| item.itemState.0 & flag.0 != 0;
        let pressed = has_state(ODS_SELECTED);
        let enabled = !has_state(ODS_DISABLED);
        let hot = enabled && (pressed || has_state(ODS_HOTLIGHT));
        let focused = has_state(ODS_FOCUS) && !has_state(ODS_NOFOCUSRECT);
        let ink = self.color(TextTone::Ink);
        let secondary = self.color(TextTone::Secondary);
        let accent = self.color(TextTone::Accent);
        let canvas = self.surface_color(Surface::Canvas);
        let card = self.surface_color(Surface::Card);
        let sidebar = self.surface_color(Surface::Sidebar);
        let selection = self.surface_color(Surface::Selection);
        let border = self.surface_color(Surface::Hairline);
        let hot_text = if hot && palette.high_contrast { palette.selection_text } else { ink };
        let (surface, fill, outline, text, role, icon, align) = match kind {
            ButtonKind::Primary => {
                let fill = if !enabled {
                    palette.disabled_fill
                } else if hot {
                    palette.primary_pressed
                } else {
                    palette.primary
                };
                let outline = if enabled { fill } else { border };
                let text = if hot && palette.high_contrast { card } else { palette.primary_text };
                (Surface::Card, fill, outline, text, FontRole::Emphasis, None, DT_CENTER)
            }
            ButtonKind::Secondary => {
                let fill = if !enabled {
                    palette.disabled_fill
                } else if hot {
                    palette.hot
                } else {
                    card
                };
                (Surface::Card, fill, border, hot_text, FontRole::Body, None, DT_CENTER)
            }
            ButtonKind::SidebarAction => {
                let fill = if !enabled {
                    palette.disabled_fill
                } else if hot {
                    palette.hot
                } else {
                    card
                };
                (Surface::Sidebar, fill, border, hot_text, FontRole::Emphasis, Some(NavigationIcon::Add), DT_LEFT)
            }
            ButtonKind::Danger => {
                let fill = if !enabled {
                    palette.disabled_fill
                } else if hot {
                    palette.danger_hot
                } else {
                    palette.danger_fill
                };
                let outline = if palette.high_contrast { border } else { fill };
                let text = if hot && palette.high_contrast { palette.selection_text } else { palette.danger };
                (Surface::Card, fill, outline, text, FontRole::Emphasis, None, DT_CENTER)
            }
            ButtonKind::Navigation { selected, icon } => {
                let (fill, text, role) = if selected || pressed {
                    (selection, palette.selection_text, FontRole::Emphasis)
                } else if hot {
                    (palette.hot, hot_text, FontRole::Body)
                } else {
                    (sidebar, ink, FontRole::Body)
                };
                (Surface::Sidebar, fill, fill, text, role, icon, DT_LEFT)
            }
            ButtonKind::Tab { selected } => {
                let (fill, text, role) = if selected && palette.high_contrast {
                    (selection, palette.selection_text, FontRole::Emphasis)
                } else if selected {
                    (canvas, accent, FontRole::Emphasis)
                } else if hot {
                    (palette.hot, hot_text, FontRole::Body)
                } else {
                    (canvas, secondary, FontRole::Body)
                };
                (Surface::Canvas, fill, fill, text, role, None, DT_CENTER)
            }
            ButtonKind::Tool { selected, icon } => {
                let (fill, text, role) = if selected {
                    (selection, palette.selection_text, FontRole::Emphasis)
                } else if hot {
                    (palette.hot, hot_text, FontRole::Body)
                } else {
                    (card, ink, FontRole::Body)
                };
                (Surface::Card, fill, fill, text, role, icon, DT_CENTER)
            }
        };

        self.fill(dc, &item.rcItem, surface);
        let mut bounds = item.rcItem;
        if matches!(kind, ButtonKind::Navigation { .. }) {
            bounds.top += self.scale(1);
            bounds.bottom -= self.scale(1);
        }
        round_box(dc, &bounds, self.scale(12), fill, outline);

        let text = if enabled { text } else { palette.disabled };
        let mut text_bounds = RECT { left: bounds.left + self.scale(10), right: bounds.right - self.scale(10), ..bounds };
        unsafe {
            let saved = SaveDC(dc);
            SelectObject(dc, self.font(role).into());
            SetTextColor(dc, text);
            SetBkMode(dc, TRANSPARENT);
            let mut text_size = SIZE::default();
            let _ = GetTextExtentPoint32W(dc, label, &mut text_size);
            let text_align = if let Some(icon) = icon {
                let middle = (bounds.top + bounds.bottom) / 2;
                let icon_and_gap = self.scale(if label.is_empty() { 14 } else { 20 });
                let mut icon_left = text_bounds.left;
                if align == DT_CENTER {
                    let width = bounds.right - bounds.left;
                    let text_space = (width - self.scale(12)).max(0);
                    let group_width = (text_size.cx + icon_and_gap).min(text_space.max(self.scale(14)));
                    icon_left = (bounds.left + bounds.right - group_width) / 2;
                }
                let icon_color =
                    if enabled && !hot && !palette.high_contrast && matches!(kind, ButtonKind::Navigation { selected: false, .. }) { secondary } else { text };
                self.draw_icon(dc, icon, icon_left, middle - self.scale(7), icon_color);
                text_bounds.left = icon_left + if align == DT_CENTER { icon_and_gap } else { self.scale(23) };
                DT_LEFT
            } else {
                align
            };
            if !label.is_empty() && text_bounds.right > text_bounds.left {
                DrawTextW(dc, label, &mut text_bounds, text_align | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
            }
            if matches!(kind, ButtonKind::Tab { selected: true }) && enabled && !palette.high_contrast {
                let width = text_size.cx.min((bounds.right - bounds.left - self.scale(20)).max(0));
                let mid = (bounds.left + bounds.right) / 2;
                let underline = RECT { left: mid - width / 2, right: mid - width / 2 + width, top: bounds.bottom - self.scale(2), bottom: bounds.bottom };
                solid_shape(dc, &underline, 0, palette.primary);
            }
            if matches!(kind, ButtonKind::Navigation { icon: Some(NavigationIcon::Computer), .. }) && pressed && !palette.high_contrast {
                let indicator =
                    RECT { left: bounds.left, top: bounds.top + self.scale(6), right: bounds.left + self.scale(2), bottom: bounds.bottom - self.scale(6) };
                solid_shape(dc, &indicator, self.scale(2), palette.primary);
            }
            if focused {
                let inset = self.scale(3);
                let focus = RECT { left: bounds.left + inset, top: bounds.top + inset, right: bounds.right - inset, bottom: bounds.bottom - inset };
                if palette.high_contrast {
                    let _ = DrawFocusRect(dc, &focus);
                } else {
                    SelectObject(dc, GetStockObject(DC_PEN));
                    SelectObject(dc, GetStockObject(NULL_BRUSH));
                    SetDCPenColor(dc, if matches!(kind, ButtonKind::Primary) { card } else { palette.primary });
                    let radius = self.scale(7);
                    let _ = RoundRect(dc, focus.left, focus.top, focus.right, focus.bottom, radius, radius);
                }
            }
            let _ = RestoreDC(dc, saved);
        }
    }

    pub(super) fn draw_icon(&self, dc: HDC, icon: NavigationIcon, x: i32, y: i32, color: COLORREF) {
        let at_x = |offset| x + self.scale(offset);
        let at_y = |offset| y + self.scale(offset);
        let point = |x, y| POINT { x: at_x(x), y: at_y(y) };
        let line = |path: &[POINT]| {
            let _ = unsafe { Polyline(dc, path) };
        };
        let rect = |left, top, right, bottom| {
            let _ = unsafe { Rectangle(dc, at_x(left), at_y(top), at_x(right), at_y(bottom)) };
        };
        unsafe {
            let saved = SaveDC(dc);
            SelectObject(dc, GetStockObject(DC_PEN));
            SelectObject(dc, GetStockObject(NULL_BRUSH));
            SetDCPenColor(dc, color);
            match icon {
                NavigationIcon::Devices => {
                    rect(0, 0, 6, 6);
                    rect(8, 0, 14, 6);
                    rect(0, 8, 6, 14);
                    rect(8, 8, 14, 14);
                }
                NavigationIcon::Sharing => {
                    line(&[point(4, 5), point(1, 5), point(1, 13), point(13, 13), point(13, 5), point(10, 5)]);
                    line(&[point(4, 3), point(7, 0), point(10, 3)]);
                    line(&[point(7, 0), point(7, 9)]);
                }
                NavigationIcon::Settings => {
                    let _ = Ellipse(dc, at_x(3), at_y(3), at_x(11), at_y(11));
                    let _ = Ellipse(dc, at_x(5), at_y(5), at_x(9), at_y(9));
                    for (inner_x, inner_y, outer_x, outer_y) in
                        [(7, 3, 7, 1), (10, 4, 12, 2), (11, 7, 13, 7), (10, 10, 12, 12), (7, 11, 7, 13), (4, 10, 2, 12), (3, 7, 1, 7), (4, 4, 2, 2)]
                    {
                        line(&[point(inner_x, inner_y), point(outer_x, outer_y)]);
                    }
                }
                NavigationIcon::Options => {
                    for (adjustment, center) in [(2, 4), (7, 9), (12, 6)] {
                        line(&[point(0, adjustment), point(center - 2, adjustment)]);
                        line(&[point(center + 2, adjustment), point(14, adjustment)]);
                        let _ = Ellipse(dc, at_x(center - 2), at_y(adjustment - 2), at_x(center + 3), at_y(adjustment + 3));
                    }
                }
                NavigationIcon::Add => {
                    line(&[point(2, 7), point(13, 7)]);
                    line(&[point(7, 2), point(7, 13)]);
                }
                NavigationIcon::Computer => {
                    rect(0, 1, 14, 11);
                    line(&[point(7, 10), point(7, 13)]);
                    line(&[point(3, 13), point(11, 13)]);
                }
                NavigationIcon::Network => {
                    line(&[point(7, 5), point(7, 8), point(2, 8), point(2, 10)]);
                    line(&[point(7, 8), point(12, 8), point(12, 10)]);
                    rect(5, 1, 10, 6);
                    rect(0, 10, 5, 15);
                    rect(10, 10, 15, 15);
                }
                NavigationIcon::Ready => {
                    line(&[point(7, 1), point(13, 4), point(12, 9), point(7, 13), point(2, 9), point(1, 4), point(7, 1)]);
                    line(&[point(4, 7), point(6, 9), point(10, 5)]);
                }
            }
            let _ = RestoreDC(dc, saved);
        }
    }
}

impl Drop for Theme {
    fn drop(&mut self) {
        unsafe {
            for font in self.fonts {
                let _ = DeleteObject(font.into());
            }
            for brush in self.brushes {
                let _ = DeleteObject(brush.into());
            }
        }
    }
}

fn scale(dpi: u32, value: i32) -> i32 {
    (value as f32 * dpi as f32 / 96.0).round() as i32
}

const fn rgb(hex: u32) -> COLORREF {
    COLORREF(((hex & 0xFF) << 16) | (hex & 0xFF00) | ((hex >> 16) & 0xFF))
}

fn solid_shape(dc: HDC, rect: &RECT, diameter: i32, color: COLORREF) {
    if diameter > 0 {
        round_box(dc, rect, diameter, color, color);
        return;
    }
    unsafe {
        let saved = SaveDC(dc);
        SetDCBrushColor(dc, color);
        FillRect(dc, rect, HBRUSH(GetStockObject(DC_BRUSH).0));
        let _ = RestoreDC(dc, saved);
    }
}

fn round_box(dc: HDC, rect: &RECT, diameter: i32, fill: COLORREF, outline: COLORREF) {
    unsafe {
        let saved = SaveDC(dc);
        SelectObject(dc, GetStockObject(DC_PEN));
        SelectObject(dc, GetStockObject(DC_BRUSH));
        SetDCPenColor(dc, outline);
        SetDCBrushColor(dc, fill);
        let _ = RoundRect(dc, rect.left, rect.top, rect.right, rect.bottom, diameter, diameter);
        let _ = RestoreDC(dc, saved);
    }
}
