import Foundation
import QuietDeskCore
import CoreGraphics
import ImageIO

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message) }
}
func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message)
}
func wait(_ semaphore: DispatchSemaphore, seconds: Double = 10, _ message: String) throws {
    try check(semaphore.wait(timeout: .now() + seconds) == .success, message)
}
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
private var successes = 0, failures = 0
func run(_ name: String, _ body: () throws -> Void) {
    do { try body(); successes += 1; print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
func withCheckFolder(_ body: (URL) throws -> Void) throws {
    let base = ProcessInfo.processInfo.environment["QUIETDESK_CHECK_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    let folder = base.appendingPathComponent("quietdesk-files-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}
func stopTransfers(_ a: ClipboardTransfer, _ b: ClipboardTransfer) {
    let done = DispatchSemaphore(value: 0)
    a.stop { done.signal() }; b.stop { done.signal() }
    _ = done.wait(timeout: .now() + 3); _ = done.wait(timeout: .now() + 3)
}
func checkPNG() throws -> Data {
    let pixels = [UInt8](repeating: 128, count: 16 * 16 * 4)
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CheckFailure("Synthetic PNG failed") }
    return data as Data
}

@main
private struct FileTransferResultChecks {
    static func main() {
        print("File checks use temporary generated files, in-process messages and pure presentation values; no network, system clipboard, credentials or permission changes.")
        run("Folder actions require locally completed file URLs, never a completion-shaped status string") {
            let sent = FileTransferNotice(result: ClipboardFileResult(direction: .sending, outcome: .completed,
                                          message: "接收完成"), keptLocalCopy: false)
            let failed = FileTransferNotice(result: ClipboardFileResult(direction: .receiving, outcome: .failed,
                                            message: "接收完成"), keptLocalCopy: false)
            try check(!sent.canOpenFolder && !failed.canOpenFolder, "Status text invented saved files")
            let saved = FileTransferNotice(result: ClipboardFileResult(direction: .receiving, outcome: .failed,
                message: "Publication failed", files: [URL(fileURLWithPath: "/synthetic/received/file")]), keptLocalCopy: false)
            try check(saved.canOpenFolder && saved.nextStep.contains("接收目录") && !saved.nextStep.contains("可以粘贴"),
                      "Publication failure hid completed files or claimed paste was ready")
        }
        run("New local copy and retained files explain why the pasteboard was not replaced") {
            let value = FileTransferNotice(result: ClipboardFileResult(direction: .receiving, outcome: .completed,
                message: "文件接收完成", files: [URL(fileURLWithPath: "/synthetic/received/file")]), keptLocalCopy: true)
            try check(value.nextStep.contains("未放入剪贴板") && value.nextStep.contains("新的本机复制") && value.canOpenFolder,
                      "Kept files were presented as paste-ready")
        }
        run("Distinct transfer outcomes have distinct identities and retry never performs a new copy") {
            let first = ClipboardFileResult(direction: .receiving, outcome: .cancelled, message: "cancelled")
            let second = ClipboardFileResult(direction: .receiving, outcome: .cancelled, message: "cancelled")
            let value = FileTransferNotice(result: first, keptLocalCopy: false)
            try check(first.id != second.id && value.title.contains("取消") && value.nextStep.contains("重新复制")
                      && !value.canOpenFolder, "Repeated results shared identity or cancellation invented an action")
        }
        runFileResultChecks()
        runFileApprovalChecks()
        runFileReceptionChecks()
        runClipboardWindowChecks()
        runClipboardStorageChecks()
        print("\(successes) passed, \(failures) failed")
        if failures != 0 { exit(1) }
    }
}
