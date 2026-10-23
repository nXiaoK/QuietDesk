import CoreGraphics
import Darwin
import Foundation
import QuietDeskCore

struct PrivacyCursorBackend {
    let setBackground: (Bool) throws -> Void
    let hide: () -> CGError
    let show: () -> CGError

    static let system = PrivacyCursorBackend(setBackground: { enabled in
        guard let connection = BackgroundCursorAPI.connection, let set = BackgroundCursorAPI.set else {
            throw DeskError.invalid("系统没有提供后台隐藏光标接口")
        }
        let id = connection()
        guard id > 0 else { throw DeskError.invalid("无法取得后台隐藏光标连接") }
        let result = set(id, id, "SetsCursorInBackground" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == .success else { throw DeskError.system("设置后台光标状态失败", result.rawValue) }
    }, hide: { CGDisplayHideCursor(CGDirectDisplayID(0)) }, show: { CGDisplayShowCursor(CGDirectDisplayID(0)) })
}

// The public hide call alone is ignored while another app is active. This private connection property
// allows it in the background without activating QuietDesk or changing the current cursor's image.
private enum BackgroundCursorAPI {
    typealias Connection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> CGError
    private static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    static let connection = function("_CGSDefaultConnection", Connection.self)
    static let set = function("CGSSetConnectionProperty", SetProperty.self)
}

/// Cursor hiding is process-wide, even with several screens or overlapping session cleanups.
/// The lock also permits a cover's final owner to release it outside the main actor.
final class PrivacyCursorController: @unchecked Sendable {
    static let shared = PrivacyCursorController(backend: .system)
    private let lock = NSLock()
    private let backend: PrivacyCursorBackend
    private var owners = Set<UUID>()
    private var hidden = false
    private var backgroundEnabled = false

    init(backend: PrivacyCursorBackend) { self.backend = backend }

    fileprivate func contains(_ owner: UUID) -> Bool { lock.withLock { owners.contains(owner) } }

    fileprivate func acquire(_ owner: UUID) throws {
        try lock.withLock {
            guard !owners.contains(owner) else { return }
            if !backgroundEnabled {
                try backend.setBackground(true)
                backgroundEnabled = true
            }
            if !hidden {
                let result = backend.hide()
                guard result == .success else {
                    let failure = DeskError.system("隐藏本机光标失败", result.rawValue).localizedDescription
                    let restoration = restoreLocked()
                    throw DeskError.invalid([failure, restoration].compactMap { $0 }.joined(separator: "；"))
                }
                hidden = true
            }
            owners.insert(owner)
        }
    }

    fileprivate func release(_ owner: UUID) -> String? {
        lock.withLock {
            owners.remove(owner)
            return restoreLocked()
        }
    }

    @discardableResult
    func retryRestoration() -> String? { lock.withLock { restoreLocked() } }

    fileprivate func removeStray(keeping owner: UUID?) -> String? {
        lock.withLock {
            owners = owners.filter { $0 == owner }
            return restoreLocked()
        }
    }

    private func restoreLocked() -> String? {
        guard owners.isEmpty else { return nil }
        if hidden {
            let result = backend.show()
            guard result == .success else {
                return DeskError.system("恢复本机光标失败，将重试恢复", result.rawValue).localizedDescription
            }
            hidden = false
        }
        if backgroundEnabled {
            do { try backend.setBackground(false); backgroundEnabled = false }
            catch { return "恢复后台光标状态失败：\(error.localizedDescription)" }
        }
        return nil
    }

    deinit { _ = restoreLocked() }
}

/// An idempotent claim on the process's single hide count. A failed show remains with the controller
/// for a later retry or a new session to reuse, rather than adding another hide count.
final class PrivacyCursorHider: @unchecked Sendable {
    private let owner = UUID()
    private let controller: PrivacyCursorController

    init(controller: PrivacyCursorController = .shared) { self.controller = controller }

    var isActive: Bool { controller.contains(owner) }
    func begin() throws { try controller.acquire(owner) }

    @discardableResult
    func end() -> String? { controller.release(owner) }

    @discardableResult
    static func removeStray(keeping live: PrivacyCursorHider?, controller: PrivacyCursorController = .shared) -> String? {
        controller.removeStray(keeping: live?.controller === controller ? live?.owner : nil)
    }

    deinit { _ = end() }
}
