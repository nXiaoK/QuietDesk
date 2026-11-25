//! Palette and owner drawing for the native workspace controls.

use windows::Win32::Foundation::{COLORREF, POINT, RECT};
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
}

#[derive(Clone, Copy)]
pub(super) enum TextTone {
    Ink,
    Secondary,
    Muted,
    Emerald,
    Amber,
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
}

#[derive(Clone, Copy)]
pub(super) enum ButtonKind {
    Primary,
    CanvasAction,
    Secondary,
    Danger,
    Navigation { selected: bool, icon: Option<NavigationIcon> },
    Tab { selected: bool },
}

struct Palette {
    high_contrast: bool,
    surfaces: [COLORREF; 5],
    text: [COLORREF; 5],
    selection: COLORREF,
    selection_text: COLORREF,
    hot: COLORREF,
    primary: COLORREF,
    primary_pressed: COLORREF,
    primary_text: COLORREF,
    danger: COLORREF,
    danger_border: COLORREF,
    danger_hot: COLORREF,
    disabled: COLORREF,
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
                surfaces: [background, background, background, background, foreground],
                text: [foreground; 5],
                selection: highlight,
                selection_text: highlight_text,
                hot: highlight,
                primary: highlight,
                primary_pressed: foreground,
                primary_text: highlight_text,
                danger: foreground,
                danger_border: foreground,
                danger_hot: highlight,
                disabled: system(COLOR_GRAYTEXT),
            };
        }

        Self {
            high_contrast,
            surfaces: [rgb(0xF5F6F8), rgb(0xECEEF1), rgb(0xFFFFFF), rgb(0xF6F7F9), rgb(0xDFE3E8)],
            text: [rgb(0x1D232A), rgb(0x525E6B), rgb(0x6D7A87), rgb(0x127A50), rgb(0x94540F)],
            selection: rgb(0xDFE5EC),
            selection_text: rgb(0x1D232A),
            hot: rgb(0xE9EDF2),
            primary: rgb(0x0A74E6),
            primary_pressed: rgb(0x0863C6),
            primary_text: rgb(0xFFFFFF),
            danger: rgb(0xB82E39),
            danger_border: rgb(0xE5B4B8),
            danger_hot: rgb(0xF9EEF0),
            disabled: rgb(0x6D7A87),
        }
    }
}

pub(super) struct Theme {
    dpi: u32,
    fonts: [HFONT; 6],
    palette: Palette,
    brushes: [HBRUSH; 5],
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
            font(25, FW_SEMIBOLD, w!("Segoe UI")),
            font(17, FW_SEMIBOLD, w!("Segoe UI")),
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

    pub(super) fn control_colors(&self, dc: HDC, surface: Surface, tone: TextTone) -> HBRUSH {
        unsafe {
            SetTextColor(dc, self.color(tone));
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
        let canvas = self.surface_color(Surface::Canvas);
        let card = self.surface_color(Surface::Card);
        let sidebar = self.surface_color(Surface::Sidebar);
        let border = self.surface_color(Surface::Hairline);
        let hot_text = if hot && palette.high_contrast { palette.selection_text } else { ink };
        let (surface, fill, outline, text, role, icon, align) = match kind {
            ButtonKind::Primary | ButtonKind::CanvasAction => {
                let surface = if matches!(kind, ButtonKind::CanvasAction) { Surface::Canvas } else { Surface::Card };
                let fill = if !enabled {
                    card
                } else if hot {
                    palette.primary_pressed
                } else {
                    palette.primary
                };
                let outline = if enabled { fill } else { border };
                let text = if hot && palette.high_contrast { card } else { palette.primary_text };
                (surface, fill, outline, text, FontRole::Emphasis, None, DT_CENTER)
            }
            ButtonKind::Secondary => {
                let fill = if hot { palette.hot } else { card };
                (Surface::Card, fill, border, hot_text, FontRole::Body, None, DT_CENTER)
            }
            ButtonKind::Danger => {
                let fill = if hot { palette.danger_hot } else { card };
                let text = if hot && palette.high_contrast { palette.selection_text } else { palette.danger };
                (Surface::Card, fill, palette.danger_border, text, FontRole::Body, None, DT_CENTER)
            }
            ButtonKind::Navigation { selected, icon } => {
                let (fill, text, role) = if selected || pressed {
                    (palette.selection, palette.selection_text, FontRole::Emphasis)
                } else if hot {
                    (palette.hot, hot_text, FontRole::Body)
                } else {
                    (sidebar, secondary, FontRole::Body)
                };
                (Surface::Sidebar, fill, fill, text, role, icon, DT_LEFT)
            }
            ButtonKind::Tab { selected } => {
                let (fill, outline, text, role) = if selected && palette.high_contrast {
                    (palette.selection, palette.selection, palette.selection_text, FontRole::Emphasis)
                } else if selected {
                    (card, border, ink, FontRole::Emphasis)
                } else if hot {
                    (palette.hot, palette.hot, hot_text, FontRole::Body)
                } else {
                    (canvas, canvas, secondary, FontRole::Body)
                };
                (Surface::Canvas, fill, outline, text, role, None, DT_CENTER)
            }
        };

        self.fill(dc, &item.rcItem, surface);
        let mut bounds = item.rcItem;
        if matches!(kind, ButtonKind::Navigation { .. }) {
            bounds.top += self.scale(1);
            bounds.bottom -= self.scale(1);
        }
        round_box(dc, &bounds, self.scale(16), fill, outline);

        let text = if enabled { text } else { palette.disabled };
        let mut text_bounds = RECT { left: bounds.left + self.scale(10), right: bounds.right - self.scale(10), ..bounds };
        if let Some(icon) = icon {
            let middle = (bounds.top + bounds.bottom) / 2;
            self.draw_icon(dc, icon, text_bounds.left, middle - self.scale(7), text);
            text_bounds.left += self.scale(23);
        }
        unsafe {
            let saved = SaveDC(dc);
            SelectObject(dc, self.font(role).into());
            SetTextColor(dc, text);
            SetBkMode(dc, TRANSPARENT);
            DrawTextW(dc, label, &mut text_bounds, align | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
            if focused {
                let inset = self.scale(3);
                let focus = RECT { left: bounds.left + inset, top: bounds.top + inset, right: bounds.right - inset, bottom: bounds.bottom - inset };
                let _ = DrawFocusRect(dc, &focus);
            }
            let _ = RestoreDC(dc, saved);
        }
    }

    fn draw_icon(&self, dc: HDC, icon: NavigationIcon, x: i32, y: i32, color: COLORREF) {
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
