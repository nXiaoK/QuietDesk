import AppKit
import CryptoKit
import QuietDeskCore

struct HostCursorSample: Sendable {
    let x: Double
    let y: Double
    let insideDisplay: Bool
    let shapeChanged: Bool
    // nil means the system shape is unknown; it does not report cursor visibility.
    let image: CursorImage?
}

@MainActor
final class HostCursorSampler {
    typealias CursorProvider = @MainActor () -> NSCursor?
    typealias LocationProvider = @MainActor () -> CGPoint
    typealias ScreenFrameProvider = @MainActor (CGDirectDisplayID) -> CGRect?
    typealias PNGEncoder = @MainActor (NSBitmapImageRep) -> Data?

    var onSample: ((HostCursorSample) -> Void)?

    private struct Position: Equatable {
        let x: Double
        let y: Double
        let inside: Bool
    }
    private let interval: TimeInterval
    private let cursorProvider: CursorProvider
    private let locationProvider: LocationProvider
    private let screenFrameProvider: ScreenFrameProvider
    private let pngEncoder: PNGEncoder
    private let clock: @MainActor () -> TimeInterval
    private var display: DisplaySnapshot
    private var timer: Timer?
    private var running = false
    private var generation: UInt64 = 0
    private var previousPosition: Position?
    private var previousShape: Data?
    private var sampledShape = false
    private struct ScratchCanvas {
        let width: Int
        let height: Int
        let bitmap: NSBitmapImageRep
        let context: NSGraphicsContext
    }

    private struct ImmutableCursorCache {
        let cgImageID: ObjectIdentifier
        let size: CGSize
        let hotSpot: CGPoint
        let fingerprint: Data
        let image: CursorImage
    }

    private var cachedImages: [Data: CursorImage] = [:]
    private var cacheOrder: [Data] = []
    private var failedRaster: (fingerprint: Data, retryAt: TimeInterval)?
    private var scratchCanvas: ScratchCanvas?
    private var immutableCache: ImmutableCursorCache?

    init(display: DisplaySnapshot, interval: TimeInterval = 1.0 / 30,
         cursorProvider: @escaping CursorProvider = { NSCursor.currentSystem },
         locationProvider: @escaping LocationProvider = { NSEvent.mouseLocation },
         screenFrameProvider: @escaping ScreenFrameProvider = { id in
             NSScreen.screens.first { screen in
                 (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
             }?.frame
         },
         pngEncoder: @escaping PNGEncoder = { $0.representation(using: .png, properties: [:]) },
         clock: @escaping @MainActor () -> TimeInterval = { SessionClock.now }) {
        self.display = display
        self.interval = interval.isFinite && interval > 0 ? max(1.0 / 120, interval) : 1.0 / 30
        self.cursorProvider = cursorProvider
        self.locationProvider = locationProvider
        self.screenFrameProvider = screenFrameProvider
        self.pngEncoder = pngEncoder
        self.clock = clock
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        let token = generation
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == token else { return }
                self.sampleNow()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sampleNow()
    }

    func stop() {
        running = false
        generation &+= 1
        timer?.invalidate(); timer = nil
        previousPosition = nil; previousShape = nil; sampledShape = false
        cachedImages.removeAll(); cacheOrder.removeAll()
        failedRaster = nil
        scratchCanvas = nil
        immutableCache = nil
    }

    func updateDisplay(_ value: DisplaySnapshot) {
        guard display != value else { return }
        display = value
        previousPosition = nil
        sampledShape = false
        if running { sampleNow() }
    }

    // Manual polls use the same coalescing and lifecycle fence as timer polls.
    func sampleNow() {
        guard running else { return }
        let token = generation
        let result = autoreleasepool { () -> (Position, Data?, CursorImage?) in
            let point = locationProvider()
            let frame = screenFrameProvider(display.id)
            let position = Self.position(point, appKitFrame: frame, quartzBounds: display.bounds)
            guard let frame, Self.validRect(frame), Self.validRect(display.bounds) else { return (position, nil, nil) }
            guard position.inside else { return (position, nil, nil) }
            guard let cursor = cursorProvider(), let (fingerprint, image) = raster(cursor) else { return (position, nil, nil) }
            return (position, fingerprint, image)
        }
        guard running, token == generation else { return }
        let shapeChanged = !sampledShape || previousShape != result.1
        guard shapeChanged || previousPosition != result.0 else { return }
        previousPosition = result.0; previousShape = result.1; sampledShape = true
        onSample?(HostCursorSample(x: result.0.x, y: result.0.y, insideDisplay: result.0.inside,
                                  shapeChanged: shapeChanged, image: result.2))
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func position(_ point: CGPoint, appKitFrame: CGRect?, quartzBounds: CGRect) -> Position {
        guard point.x.isFinite, point.y.isFinite, let frame = appKitFrame,
              validRect(frame), validRect(quartzBounds) else { return Position(x: 0, y: 0, inside: false) }
        // Pair the sampled display's AppKit frame with its Quartz bounds. No global
        // desktop-height guess or backing-pixel multiplication is needed on Retina.
        let quartzX = quartzBounds.minX + (point.x - frame.minX) * quartzBounds.width / frame.width
        let quartzY = quartzBounds.minY + (frame.maxY - point.y) * quartzBounds.height / frame.height
        let x = Double((quartzX - quartzBounds.minX) / quartzBounds.width)
        let y = Double((quartzY - quartzBounds.minY) / quartzBounds.height)
        guard x.isFinite, y.isFinite else { return Position(x: 0, y: 0, inside: false) }
        let inside = x >= 0 && x < 1 && y >= 0 && y < 1
        return Position(x: min(1, max(0, x)), y: min(1, max(0, y)), inside: inside)
    }

    private func raster(_ cursor: NSCursor) -> (Data, CursorImage)? {
        let image = cursor.image
        let size = image.size, hotSpot = cursor.hotSpot
        guard size.width.isFinite, size.height.isFinite, (0.5...256).contains(size.width),
              (0.5...256).contains(size.height), hotSpot.x.isFinite, hotSpot.y.isFinite,
              hotSpot.x >= 0, hotSpot.y >= 0, hotSpot.x <= size.width, hotSpot.y <= size.height else { return nil }
        let representations = image.representations
        let hasMutableBitmapRep = representations.contains { $0 is NSBitmapImageRep }
        let backingCGImage = hasMutableBitmapRep ? nil : image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let backingCGImage, let cached = immutableCache,
           cached.cgImageID == ObjectIdentifier(backingCGImage), cached.size == size, cached.hotSpot == hotSpot {
            return (cached.fingerprint, cached.image)
        }
        let representationScale = representations.compactMap { representation -> CGFloat? in
            guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return nil }
            return min(CGFloat(representation.pixelsWide) / size.width, CGFloat(representation.pixelsHigh) / size.height)
        }.max() ?? 2
        let scale = min(2, max(1, representationScale))
        let reduction = min(1, 256 / max(size.width * scale, size.height * scale))
        let width = max(1, min(256, Int((size.width * scale * reduction).rounded())))
        let height = max(1, min(256, Int((size.height * scale * reduction).rounded())))
        let canvas: ScratchCanvas
        if let existing = scratchCanvas, existing.width == width, existing.height == height {
            canvas = existing
        } else {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            bitmap.size = CGSize(width: width, height: height)
            let created = ScratchCanvas(width: width, height: height, bitmap: bitmap, context: context)
            scratchCanvas = created
            canvas = created
        }
        let bitmap = canvas.bitmap
        let context = canvas.context
        guard let pixels = bitmap.bitmapData else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.cgContext.clear(rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: CGRect(origin: .zero, size: size), operation: .copy, fraction: 1,
                   respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        var hasher = SHA256()
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 36) { buffer in
            var offset = 0
            for value in [Double(size.width), Double(size.height), Double(hotSpot.x), Double(hotSpot.y)] {
                let bits = value.bitPattern.bigEndian
                withUnsafeBytes(of: bits) { bytes in
                    buffer.baseAddress!.advanced(by: offset).update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 8)
                }
                offset += 8
            }
            let rawWidth = UInt16(width).bigEndian
            let rawHeight = UInt16(height).bigEndian
            for dimension in [rawWidth, rawHeight] {
                withUnsafeBytes(of: dimension) { bytes in
                    buffer.baseAddress!.advanced(by: offset).update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 2)
                }
                offset += 2
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        let fingerprint = Data(hasher.finalize())
        if let cached = cachedImages[fingerprint] {
            cacheOrder.removeAll { $0 == fingerprint }; cacheOrder.append(fingerprint)
            if let backingCGImage {
                immutableCache = ImmutableCursorCache(cgImageID: ObjectIdentifier(backingCGImage), size: size, hotSpot: hotSpot,
                                                      fingerprint: fingerprint, image: cached)
            }
            return (fingerprint, cached)
        }
        let now = clock()
        if let failedRaster, failedRaster.fingerprint == fingerprint, now.isFinite, now < failedRaster.retryAt { return nil }
        guard let png = pngEncoder(bitmap), !png.isEmpty, png.count <= 256 * 1024,
              let value = try? CursorImage(png: png, pixelWidth: width, pixelHeight: height,
                  logicalWidth: Double(size.width), logicalHeight: Double(size.height),
                  hotSpotX: Double(hotSpot.x), hotSpotY: Double(hotSpot.y)) else {
            failedRaster = (fingerprint, now.isFinite ? now + 1 : 0)
            immutableCache = nil
            return nil
        }
        failedRaster = nil
        if cacheOrder.count >= 8, let oldest = cacheOrder.first {
            cacheOrder.removeFirst(); cachedImages.removeValue(forKey: oldest)
        }
        cachedImages[fingerprint] = value; cacheOrder.append(fingerprint)
        if let backingCGImage {
            immutableCache = ImmutableCursorCache(cgImageID: ObjectIdentifier(backingCGImage), size: size, hotSpot: hotSpot,
                                                  fingerprint: fingerprint, image: value)
        } else {
            immutableCache = nil
        }
        return (fingerprint, value)
    }

    deinit { timer?.invalidate() }
}
