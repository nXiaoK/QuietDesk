import CoreGraphics
import Darwin
import Foundation
import IOKit.ps
import QuietDeskCore

/// DisplayServices is a private framework without a public header. Only functions whose signatures were
/// confirmed on macOS 26 are bound here; several of its other exports crash when called with a guessed one.
private enum DisplayServices {
    typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
    static let canChange = function("DisplayServicesCanChangeBrightness", CanChange.self)
    static let get = function("DisplayServicesGetBrightness", GetBrightness.self)
    static let set = function("DisplayServicesSetBrightness", SetBrightness.self)
}

/// One display's brightness through DisplayServices, the path the brightness keys take.
struct DisplayServicesBrightnessIO: DisplayBrightnessIO, Sendable {
    let display: CGDirectDisplayID

    func brightness() throws -> Float {
        guard let get = DisplayServices.get else { throw DeskError.invalid("系统没有提供屏幕亮度接口") }
        var value: Float = -1
        let status = get(display, &value)
        guard status == 0 else { throw DeskError.system("读取内建屏幕亮度失败", status) }
        guard value.isFinite, (0...1).contains(value) else { throw DeskError.invalid("内建屏幕亮度读数无效") }
        return value
    }

    func setBrightness(_ value: Float) throws {
        guard let set = DisplayServices.set else { throw DeskError.invalid("系统没有提供屏幕亮度接口") }
        let status = set(display, value)
        guard status == 0 else { throw DeskError.system("调节内建屏幕亮度失败", status) }
    }
}

/// Turns a laptop's built-in display dark for the session. Brightness only drives the backlight, so the
/// picture sent to the viewer is unaffected.
@MainActor
final class BuiltInDisplayDimmer: SessionDisplayDimming {
    nonisolated static let watchdogArgument = "--quietdesk-display-dim-watchdog-v1"
    var onEnded: ((String) -> Void)?
    var isDimmed: Bool { dimming != nil }
    private var dimming: (transaction: DisplayDimTransaction, io: DisplayServicesBrightnessIO, watchdog: DisplayDimWatchdogClient)?
    private var monitor: Task<Void, Never>?

    var unavailableReason: String? {
        do { _ = try Self.builtInDisplay(); return nil } catch { return error.localizedDescription }
    }

    func dim() async throws {
        guard dimming == nil else { return }
        let io = try Self.builtInDisplay()
        let transaction = try DisplayDimTransaction.begin(using: io)
        // The helper holds the original brightness, so a crash or forced quit cannot leave the display dark.
        let watchdog = try DisplayDimWatchdogClient(display: io.display, original: transaction.original)
        watchdog.onExit = { [weak self, weak watchdog] in
            guard let self, let watchdog else { return }
            self.watchdogExited(watchdog)
        }
        do {
            try Task.checkCancellation()
            try transaction.dim(using: io)
            try await Self.waitUntilDark(io)
            guard !watchdog.hasExited else { throw DeskError.invalid("亮度恢复子进程已结束，未调暗内建屏幕") }
        } catch {
            _ = try? transaction.restore(using: io)
            watchdog.release()
            throw error
        }
        dimming = (transaction, io, watchdog)
        watchBrightness()
    }

    func restore() -> String? {
        monitor?.cancel(); monitor = nil
        guard let dimming else { return nil }
        do { try dimming.transaction.restore(using: dimming.io) }
        catch { return "内建屏幕亮度未能恢复：\(error.localizedDescription)；可在被控 Mac 上按亮度键调亮" }
        self.dimming = nil
        dimming.watchdog.release()
        return nil
    }

    func holdForLock() { dimming?.watchdog.holdForLock() }

    /// The laptop's built-in display, while its brightness can be read and changed.
    private static func builtInDisplay() throws -> DisplayServicesBrightnessIO {
        guard DisplayServices.canChange != nil, DisplayServices.get != nil, DisplayServices.set != nil else {
            throw DeskError.invalid("被控端系统没有提供内建屏幕亮度接口")
        }
        guard hasInternalBattery else { throw DeskError.invalid("被控端不是笔记本，亮度归零只用于笔记本的内建屏幕") }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw DeskError.invalid("被控端内建屏幕没有点亮（可能已合盖）")
        }
        guard DisplayServices.canChange?(display) == true else { throw DeskError.invalid("被控端内建屏幕当前不能调节亮度") }
        let io = DisplayServicesBrightnessIO(display: display)
        _ = try io.brightness()
        return io
    }

    private static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private static func waitUntilDark(_ io: DisplayServicesBrightnessIO) async throws {
        for _ in 0..<40 {
            if DisplayDimTransaction.isDark(try io.brightness()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DeskError.invalid("内建屏幕亮度没有降到 0")
    }

    /// Brightness keys, Control Center or auto-brightness on the host end the dimming; the switch turns off
    /// instead of pushing the brightness back down.
    private func watchBrightness() {
        monitor?.cancel()
        guard let io = dimming?.io else { return }
        monitor = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let reading = await Task.detached { try? io.brightness() }.value
                guard let self, !Task.isCancelled, self.dimming != nil else { return }
                guard let reading, !DisplayDimTransaction.isDark(reading) else { continue }
                self.end("被控 Mac 本机调高了内建屏幕亮度，亮度归零已关闭")
                return
            }
        }
    }

    /// Dimming ended without a request; the brightness stays as it is now.
    private func end(_ reason: String) {
        guard let dimming else { return }
        self.dimming = nil
        monitor?.cancel(); monitor = nil
        dimming.watchdog.release()
        onEnded?(reason)
    }

    private func watchdogExited(_ watchdog: DisplayDimWatchdogClient) {
        guard let dimming, dimming.watchdog === watchdog else { return }
        // Without the helper a crash could leave the display dark, so the brightness comes back now.
        _ = try? dimming.transaction.restore(using: dimming.io)
        end("亮度恢复子进程已结束，亮度归零已取消")
    }
}

/// The app's end of the helper that puts the brightness back when the app goes away while the display is dark.
/// The helper learns this from the end of its input: closing it without "release" means the app is gone.
@MainActor
final class DisplayDimWatchdogClient {
    private let process = Process()
    private let input: FileHandle
    private var released = false
    private(set) var hasExited = false
    var onExit: (() -> Void)?
    var processIdentifier: Int32 { process.processIdentifier }

    init(display: CGDirectDisplayID, original: Float, executable: URL? = Bundle.main.executableURL) throws {
        guard let executable else { throw DeskError.invalid("无法找到亮度恢复子进程") }
        let pipe = Pipe()
        input = pipe.fileHandleForWriting
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw DeskError.invalid("无法保护亮度恢复子进程管道") }
        process.executableURL = executable
        process.arguments = [BuiltInDisplayDimmer.watchdogArgument, String(display), String(original)]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hasExited = true
                if !self.released { self.onExit?() }
            }
        }
        try process.run()
        try? pipe.fileHandleForReading.close()
    }

    /// A session lock was just requested; if the app goes away now, the helper waits for the lock first.
    func holdForLock() {
        guard !released else { return }
        try? input.write(contentsOf: Data("lock\n".utf8))
    }

    /// The app has put the brightness back itself or no longer owns it; the helper ends without writing.
    func release() {
        guard !released else { return }
        released = true
        try? input.write(contentsOf: Data("release\n".utf8))
        try? input.close()
    }

    deinit { if !released { try? input.close() } }
}

/// The helper process: it holds the brightness the session found and puts it back if the app goes away
/// while the display is still dark.
enum DisplayDimWatchdog {
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments,
                               io: (CGDirectDisplayID) -> DisplayBrightnessIO = { DisplayServicesBrightnessIO(display: $0) },
                               isLocked: () -> Bool = { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true }) -> Bool {
        guard let index = arguments.firstIndex(of: BuiltInDisplayDimmer.watchdogArgument) else { return false }
        guard index + 2 < arguments.count, let display = CGDirectDisplayID(arguments[index + 1]),
              let original = Float(arguments[index + 2]), original.isFinite, (0...1).contains(original) else { return true }
        serve(AnyIterator { readLine(strippingNewline: true) }, restoring: DisplayDimTransaction(original: original),
              using: io(display), isLocked: isLocked)
        return true
    }

    /// Follows the app's lines until it releases the display or goes away. Once it has gone, the original
    /// brightness comes back if the display is still dark, after the lock the app had just asked for.
    static func serve(_ lines: AnyIterator<String>, restoring transaction: DisplayDimTransaction, using io: DisplayBrightnessIO,
                      isLocked: () -> Bool, lockWait: TimeInterval = 4) {
        var waitsForLock = false
        for line in lines {
            if line == "release" { return }
            if line == "lock" { waitsForLock = true }
        }
        if waitsForLock {
            let deadline = Date().addingTimeInterval(lockWait)
            while !isLocked(), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        for attempt in 0..<3 {
            if (try? transaction.restore(using: io)) != nil { return }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
        }
    }
}
