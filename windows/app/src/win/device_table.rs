//! The native, single-selection table for saved connections.

use super::util::wide;
use windows::Win32::Foundation::{E_FAIL, HWND, LPARAM, WPARAM};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::WindowsAndMessaging::SendMessageW;
use windows::core::{Error, PWSTR, Result};

pub(super) fn initialize(table: HWND) -> Result<()> {
    let styles = (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_LABELTIP) as usize;
    send(table, LVM_SETEXTENDEDLISTVIEWSTYLE, styles, styles as isize);
    for (index, title) in ["设备", "连接端点"].into_iter().enumerate() {
        let mut title = wide(title);
        let column = LVCOLUMNW { mask: LVCF_TEXT | LVCF_SUBITEM, pszText: PWSTR(title.as_mut_ptr()), iSubItem: index as i32, ..Default::default() };
        if send(table, LVM_INSERTCOLUMNW, index, std::ptr::from_ref(&column) as isize) == -1 {
            return Err(Error::new(E_FAIL, "无法创建已保存设备的表格列"));
        }
    }
    Ok(())
}

pub(super) fn replace<'a>(table: HWND, rows: impl Iterator<Item = (&'a str, &'a str)>) -> Result<()> {
    if send(table, LVM_DELETEALLITEMS, 0, 0) == 0 {
        return Err(Error::new(E_FAIL, "无法清除已保存设备的表格行"));
    }
    for (index, (name, endpoint)) in rows.enumerate() {
        let mut name = wide(name);
        let mut endpoint = wide(endpoint);
        let item = LVITEMW { mask: LVIF_TEXT, iItem: index as i32, pszText: PWSTR(name.as_mut_ptr()), ..Default::default() };
        let subitem = LVITEMW { iSubItem: 1, pszText: PWSTR(endpoint.as_mut_ptr()), ..Default::default() };
        let inserted = send(table, LVM_INSERTITEMW, 0, std::ptr::from_ref(&item) as isize);
        if inserted != index as isize || send(table, LVM_SETITEMTEXTW, index, std::ptr::from_ref(&subitem) as isize) == 0 {
            send(table, LVM_DELETEALLITEMS, 0, 0);
            return Err(Error::new(E_FAIL, "无法更新已保存设备的表格行"));
        }
    }
    Ok(())
}

pub(super) fn resize(table: HWND, width: i32, dpi: u32) {
    let max_name_width = (280 * dpi / 96) as i32;
    let name_width = (width * 42 / 100).min(max_name_width);
    send(table, LVM_SETCOLUMNWIDTH, 0, name_width as isize);
    send(table, LVM_SETCOLUMNWIDTH, 1, LVSCW_AUTOSIZE_USEHEADER as isize);
}

pub(super) fn selected(table: HWND) -> Option<usize> {
    usize::try_from(send(table, LVM_GETNEXTITEM, usize::MAX, LVNI_SELECTED as isize)).ok()
}

pub(super) fn select(table: HWND, index: Option<usize>) {
    let state_mask = LIST_VIEW_ITEM_STATE_FLAGS(LVIS_SELECTED.0 | LVIS_FOCUSED.0);
    let state = if index.is_some() { state_mask } else { LIST_VIEW_ITEM_STATE_FLAGS(0) };
    let item = LVITEMW { state, stateMask: state_mask, ..Default::default() };
    send(table, LVM_SETITEMSTATE, index.unwrap_or(usize::MAX), std::ptr::from_ref(&item) as isize);
    if let Some(index) = index {
        send(table, LVM_ENSUREVISIBLE, index, 0);
    }
}

fn send(table: HWND, message: u32, wparam: usize, lparam: isize) -> isize {
    unsafe { SendMessageW(table, message, Some(WPARAM(wparam)), Some(LPARAM(lparam))) }.0
}
