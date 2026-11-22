import AppKit
import ApplicationServices
import Carbon
import QuietDeskCore

/// Finder's Paste cannot be recognised on this Mac right now. The copy can still be offered the way it is
/// to a peer without file names, where the files are requested once something reads the pasteboard.
struct FinderPasteUnavailable: Error {
    let reason: String
}

/// Watches only Finder, and only between publishing a remote file copy and its first paste.
/// No event is intercepted, retained or replayed.
@MainActor
private final class FinderPasteIntent {
    private let finder: NSRunningApplication
    private let app: AXUIElement
    private let paste: () -> Void
    private var tap: CFMachPort?
    private var observer: AXObserver?

    init(isTrusted: () -> Bool, paste: @escaping () -> Void) throws {
        guard isTrusted() else { throw FinderPasteUnavailable(reason: "辅助功能权限未生效") }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw FinderPasteUnavailable(reason: "Finder 未运行")
        }
        self.finder = finder
        self.app = AXUIElementCreateApplication(finder.processIdentifier)
        self.paste = paste
        AXUIElementSetMessagingTimeout(app, 0.2)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreateForPid(pid: finder.processIdentifier, place: .headInsertEventTap, options: .listenOnly,
                                              eventsOfInterest: mask, callback: { _, type, event, pointer in
            if let pointer {
                MainActor.assumeIsolated {
                    Unmanaged<FinderPasteIntent>.fromOpaque(pointer).takeUnretainedValue().observe(type, event)
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else { throw FinderPasteUnavailable(reason: "无法监听 Finder 的粘贴操作，请检查辅助功能和输入监控权限") }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        var observer: AXObserver?
        if AXObserverCreate(finder.processIdentifier, { _, element, _, pointer in
            if let pointer { MainActor.assumeIsolated {
                let watcher = Unmanaged<FinderPasteIntent>.fromOpaque(pointer).takeUnretainedValue()
                if watcher.finder.isActive, watcher.isPasteMenuItem(element) { watcher.paste() }
            } }
        }, &observer) == .success, let observer,
           AXObserverAddNotification(observer, app, kAXMenuItemSelectedNotification as CFString, context) == .success {
            self.observer = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        observer = nil
        tap = nil
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        guard attribute(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
              attribute(element, kAXEnabledAttribute) as? Bool != false else { return false }
        if let key = attribute(element, kAXMenuItemCmdCharAttribute) as? String, key.uppercased() == "V",
           (attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0 { return true }
        // Finder's contextual menu can omit the key equivalent. Match its native Edit-menu action title.
        guard let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty,
              let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let menuBar = unsafeDowncast(bar, to: AXUIElement.self)
        for top in attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            for menu in attribute(top, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                for item in attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    if attribute(item, kAXTitleAttribute) as? String == title,
                       (attribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "V",
                       (attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0 { return true }
                }
            }
        }
        return false
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard finder.isActive else { return }
        if type == .keyDown {
            let flags = event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
            guard flags == .maskCommand, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let key = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
            guard key == "v" || ((key ?? "").isEmpty && event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_V) else { return }
            if let focus = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID(),
               let role = attribute(unsafeDowncast(focus, to: AXUIElement.self), kAXRoleAttribute) as? String,
               [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return }
            paste()
        } else if type == .leftMouseDown {
            var item: AXUIElement?
            let point = event.location
            if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &item) == .success,
               let item, isPasteMenuItem(item) { paste() }
        }
    }
}

final class PromisedFinderRoot: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let provide: () -> Bool
    private let failed: () -> Void
    private let parked: URL
    private let lock = NSLock()
    private var otherReaders = 0

    init(url: URL, queue: OperationQueue, failed: @escaping () -> Void, provide: @escaping () -> Bool) {
        self.presentedItemURL = url
        self.presentedItemOperationQueue = queue
        self.provide = provide
        self.failed = failed
        self.parked = url.deletingLastPathComponent().appendingPathComponent(".quietdesk-\(UUID().uuidString)")
    }

    func relinquishPresentedItem(toReader reader: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        if provide() { reader(nil); return }
        guard let url = presentedItemURL else { reader(nil); return }
        // Finder also coordinates reads reached through accessibility or by another process. If the
        // user did not choose Paste, the reader must not see a copyable placeholder at this path.
        lock.withLock {
            otherReaders += 1
            if otherReaders == 1, renamex_np(url.path, parked.path, UInt32(RENAME_EXCL)) != 0, errno != ENOENT {
                // Both paths are inside our private staging directory. Withhold the stub even on an I/O error.
                if unlink(url.path) != 0 { _ = chmod(url.path, 0) }
                failed()
            }
        }
        reader { [self] in
            lock.withLock {
                otherReaders -= 1
                if otherReaders == 0, renamex_np(parked.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                    if errno == EEXIST { _ = unlink(parked.path) } // A real paste has already materialized the root.
                    else if errno != ENOENT { failed() }
                }
            }
        }
    }
}

/// Finder coordinates the read of a regular source before copying it. A folder source alone
/// can be enumerated without coordination, so every root starts as a same-name regular file.
final class FinderClipboardPaste: @unchecked Sendable {
    let promise: ClipboardFilePromise
    let urls: [URL]
    private let directory: URL
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var intentUntil: TimeInterval = 0
    private var began = false
    private let onFailure: @MainActor (String) -> Void
    private var reportedFailure = false
    private var materialized = false // confined to the serial presenter queue
    private var readers: [PromisedFinderRoot] = []
    @MainActor private var monitor: FinderPasteIntent?

    /// Throws `FinderPasteUnavailable` when Finder's Paste cannot be watched, and leaves nothing behind then.
    @MainActor init(names: [String], promise: ClipboardFilePromise, isTrusted: () -> Bool = { AXIsProcessTrusted() },
                    onFailure: @escaping @MainActor (String) -> Void = { _ in }) throws {
        self.onFailure = onFailure
        self.promise = promise
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("QuietDesk-\(UUID().uuidString).noindex", isDirectory: true)
        directory = staging
        urls = names.map { staging.appendingPathComponent($0, isDirectory: false) }
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (name, url) in zip(names, urls) {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                      !name.contains("\0"), name.utf8.count <= 255 else { throw DeskError.invalid("对端文件名无效，请重新复制") }
                try Data().write(to: url, options: .withoutOverwriting)
            }
            monitor = try FinderPasteIntent(isTrusted: isTrusted) { [weak self] in self?.recordPaste() }
            readers = urls.map { url in
                PromisedFinderRoot(url: url, queue: queue, failed: { [weak self] in
                    self?.reportFailure("Finder 的临时文件不可用，请在对端重新复制")
                }) { [weak self] in self?.provideForFinder() ?? false }
            }
            readers.forEach(NSFileCoordinator.addFilePresenter)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func reportFailure(_ message: String) {
        let first = lock.withLock {
            if reportedFailure { return false }
            reportedFailure = true
            return true
        }
        if first { DispatchQueue.main.async { [weak self] in self?.onFailure(message) } }
    }

    private func recordPaste() {
        lock.withLock { intentUntil = ProcessInfo.processInfo.systemUptime + 2 }
    }

    private func provideForFinder() -> Bool {
        if materialized { return true }
        let accepted = lock.withLock {
            guard !began, ProcessInfo.processInfo.systemUptime <= intentUntil else { return false }
            began = true
            return true
        }
        guard accepted else {
            if !AXIsProcessTrusted() { reportFailure("QuietDesk 的辅助功能权限已失效，请允许后在对端重新复制文件") }
            return false
        }
        DispatchQueue.main.async { [weak self] in self?.monitor?.stop() }
        guard promise.url(at: 0) != nil, let files = promise.files else {
            try? FileManager.default.removeItem(at: directory)
            return false
        }
        do {
            var sources: [String: URL] = [:]
            for file in files { sources[file.lastPathComponent] = file }
            guard sources.count == urls.count else { throw DeskError.invalid("接收的文件清单已改变") }
            for url in urls {
                guard let source = sources[url.lastPathComponent] else { throw DeskError.invalid("接收的文件名与清单不符") }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: source, to: url)
            }
            materialized = true
        } catch {
            try? FileManager.default.removeItem(at: directory)
            reportFailure("Finder 无法粘贴已收到的文件，可从 QuietDesk 的接收目录取回：\(error.localizedDescription)")
        }
        return materialized
    }

    @MainActor func stop() {
        monitor?.stop()
        monitor = nil
        promise.finish(nil)
        readers.forEach(NSFileCoordinator.removeFilePresenter)
        readers.removeAll()
    }

    deinit {
        readers.forEach(NSFileCoordinator.removeFilePresenter)
        let directory = directory
        // Finder can still be copying these paths after the application or the user replaces the pasteboard.
        // Let any existing coordinated reads finish before deleting our private folder.
        DispatchQueue.global(qos: .utility).async {
            NSFileCoordinator().coordinate(writingItemAt: directory, options: .forDeleting, error: nil) { folder in
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
