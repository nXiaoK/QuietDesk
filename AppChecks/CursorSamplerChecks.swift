import AppKit
import QuietDeskCore

private struct CursorSamplerCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CursorSamplerCheckFailure(message) }
}

@MainActor
private final class CursorProbe: NSCursor {
    let sampledImage: NSImage
    let sampledHotSpot: CGPoint
    override var image: NSImage { sampledImage }
    override var hotSpot: NSPoint { sampledHotSpot }

    override init(image: NSImage, hotSpot: CGPoint) {
        sampledImage = image; sampledHotSpot = hotSpot
        super.init(image: NSImage(size: CGSize(width: 1, height: 1)), hotSpot: .zero)
    }

    required init(coder: NSCoder) {
        sampledImage = NSImage(size: CGSize(width: 1, height: 1)); sampledHotSpot = .zero
        super.init(image: sampledImage, hotSpot: .zero)
    }
}

@MainActor
private func image(width: Int = 16, height: Int = 12, logicalSize: CGSize? = nil, blue: Bool = false, transparentCorner: Bool = false) throws -> NSImage {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32), let pixels = bitmap.bitmapData else {
        throw CursorSamplerCheckFailure("Could not allocate a synthetic cursor")
    }
    for row in 0..<height {
        for column in 0..<width {
            let offset = (row * width + column) * 4
            pixels[offset] = blue ? 0 : 255
            pixels[offset + 1] = UInt8((row + column) % 128)
            pixels[offset + 2] = blue ? 255 : 0
            pixels[offset + 3] = 255
            if transparentCorner, row == 0, column == 0 {
                for component in 0..<4 { pixels[offset + component] = 0 }
            }
        }
    }
    let size = logicalSize ?? CGSize(width: width, height: height)
    bitmap.size = size
    let result = NSImage(size: size)
    result.addRepresentation(bitmap)
    return result
}

private func display(_ id: UInt32 = 1, bounds: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900), retina: Bool = false) -> DisplaySnapshot {
    DisplaySnapshot(id: id, pixelWidth: retina ? 2880 : 1440, pixelHeight: retina ? 1800 : 900, bounds: bounds)
}

@MainActor
private func drain(_ seconds: TimeInterval = 0.08) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

@main
@MainActor
private struct CursorSamplerChecks {
    static func main() {
        if CommandLine.arguments.contains("--probe-system-cursor") {
            print(NSCursor.currentSystem == nil ? "currentSystem=unknown" : "currentSystem=known")
            return
        }
        var passed = 0, failed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }

        run("Known cursor PNG preserves logical size and point hotspot") {
            let source = try image(width: 32, height: 24, logicalSize: CGSize(width: 16, height: 12))
            let cursor = CursorProbe(image: source, hotSpot: CGPoint(x: 3, y: 4))
            var samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(retina: true), cursorProvider: { cursor },
                locationProvider: { CGPoint(x: 720, y: 450) }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            guard let sample = samples.first, let raster = sample.image else { throw CursorSamplerCheckFailure("No known cursor") }
            try require(sample.insideDisplay && sample.x == 0.5 && sample.y == 0.5 && sample.shapeChanged, "Initial cursor position or shape was wrong")
            try require(raster.pixelWidth == 32 && raster.pixelHeight == 24 && raster.logicalWidth == 16 && raster.logicalHeight == 12,
                        "Retina cursor pixels were confused with logical points")
            try require(raster.hotSpotX == 3 && raster.hotSpotY == 4 && raster.png.count <= 256 * 1024, "Hotspot or PNG limit changed")
            guard let decoded = NSBitmapImageRep(data: raster.png) else { throw CursorSamplerCheckFailure("Cursor PNG did not decode") }
            try require(decoded.pixelsWide == 32 && decoded.pixelsHigh == 24, "PNG metadata did not match the raster")
        }

        run("Target-display coordinates handle negative origins, vertical layout and Retina") {
            let layouts: [(CGRect, CGRect, CGPoint, Double, Double)] = [
                (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 900), CGPoint(x: 0, y: 900), 0, 0),
                (CGRect(x: -1920, y: 120, width: 1920, height: 1080), CGRect(x: -1920, y: -300, width: 1920, height: 1080), CGPoint(x: -1440, y: 930), 0.25, 0.25),
                (CGRect(x: 0, y: 900, width: 2560, height: 1440), CGRect(x: 0, y: -1440, width: 2560, height: 1440), CGPoint(x: 1280, y: 1980), 0.5, 0.25),
                (CGRect(x: 1440, y: -1080, width: 1920, height: 1080), CGRect(x: 1440, y: 900, width: 1920, height: 1080), CGPoint(x: 2880, y: -540), 0.75, 0.5),
                (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -200, y: 100, width: 2880, height: 1800), CGPoint(x: 360, y: 675), 0.25, 0.25)
            ]
            for (appKit, quartz, point, x, y) in layouts {
                var sample: HostCursorSample?
                let sampler = HostCursorSampler(display: display(bounds: quartz, retina: true), cursorProvider: { nil },
                    locationProvider: { point }, screenFrameProvider: { _ in appKit })
                sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
                try require(sample?.insideDisplay == true && abs((sample?.x ?? -1) - x) < 0.000001 && abs((sample?.y ?? -1) - y) < 0.000001,
                            "Display-relative AppKit/Quartz mapping failed")
            }
        }

        run("Cursor raster preserves transparent pixels") {
            let cursor = CursorProbe(image: try image(transparentCorner: true), hotSpot: .zero)
            var sample: HostCursorSample?
            let sampler = HostCursorSampler(display: display(), cursorProvider: { cursor }, locationProvider: { CGPoint(x: 100, y: 100) },
                screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
            sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
            guard let png = sample?.image?.png, let bitmap = NSBitmapImageRep(data: png) else { throw CursorSamplerCheckFailure("Transparent cursor did not encode") }
            var transparent = false, opaque = false
            for row in 0..<bitmap.pixelsHigh {
                for column in 0..<bitmap.pixelsWide {
                    let alpha = bitmap.colorAt(x: column, y: row)?.alphaComponent ?? -1
                    transparent = transparent || alpha < 0.01
                    opaque = opaque || alpha > 0.99
                }
            }
            try require(transparent && opaque, "Cursor transparency was replaced with an opaque background")
        }

        run("Outside and invalid coordinates remain finite and never claim visibility") {
            for point in [CGPoint(x: -1, y: 100), CGPoint(x: 1440, y: 100), CGPoint(x: 10, y: 0), CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 10, y: CGFloat.infinity)] {
                var sample: HostCursorSample?
                let sampler = HostCursorSampler(display: display(), cursorProvider: { nil }, locationProvider: { point },
                    screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
                sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
                try require(sample?.insideDisplay == false && sample?.x.isFinite == true && sample?.y.isFinite == true && sample?.image == nil,
                            "Outside/invalid position became a valid in-display cursor")
            }
        }

        run("Missing display mapping reports unknown without reading system shape") {
            var reads = 0, samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), cursorProvider: { reads += 1; return nil },
                locationProvider: { CGPoint(x: 3, y: 4) }, screenFrameProvider: { _ in nil })
            sampler.onSample = { samples.append($0) }; sampler.start(); sampler.stop()
            try require(reads == 0 && samples.count == 1 && !samples[0].insideDisplay && samples[0].image == nil,
                        "Unknown display mapping read unrelated cursor geometry")
        }

        run("Cursor outside the shared display is not sampled and returning restores its shape") {
            let cursor = CursorProbe(image: try image(), hotSpot: CGPoint(x: 2, y: 3))
            var reads = 0, encodes = 0, point = CGPoint(x: 100, y: 100), samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), cursorProvider: { reads += 1; return cursor },
                locationProvider: { point }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                pngEncoder: { bitmap in encodes += 1; return bitmap.representation(using: .png, properties: [:]) })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            point = CGPoint(x: 1600, y: 100); sampler.sampleNow(); sampler.sampleNow()
            try require(reads == 1 && encodes == 1 && samples.count == 2 && !samples[1].insideDisplay
                        && samples[1].shapeChanged && samples[1].image == nil,
                        "An unshared display exposed its cursor image or retained the previous known shape")
            point = CGPoint(x: 120, y: 100); sampler.sampleNow()
            try require(reads == 2 && encodes == 1 && samples.count == 3 && samples[2].insideDisplay
                        && samples[2].shapeChanged && samples[2].image != nil,
                        "Returning to the shared display did not restore the observed shape")
        }

        run("Pixel hash coalesces equivalent cursor instances and encodes PNG once") {
            let source = try image()
            var point = CGPoint(x: 100, y: 100), encodes = 0, samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), cursorProvider: { CursorProbe(image: source, hotSpot: .zero) },
                locationProvider: { point }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                pngEncoder: { bitmap in encodes += 1; return bitmap.representation(using: .png, properties: [:]) })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            for _ in 0..<20 { sampler.sampleNow() }
            try require(encodes == 1 && samples.count == 1, "Unchanged cursors were re-encoded or emitted each poll")
            point = CGPoint(x: 120, y: 130); sampler.sampleNow()
            try require(encodes == 1 && samples.count == 2 && !samples[1].shapeChanged && samples[1].image != nil,
                        "Position update re-encoded the same shape")
        }

        run("Shape and hotspot changes update independently of cursor identity") {
            let red = try image(), blue = try image(blue: true)
            var cursor: NSCursor? = CursorProbe(image: red, hotSpot: .zero)
            var samples: [HostCursorSample] = [], encodes = 0
            let sampler = HostCursorSampler(display: display(), cursorProvider: { cursor }, locationProvider: { CGPoint(x: 100, y: 100) },
                screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                pngEncoder: { bitmap in encodes += 1; return bitmap.representation(using: .png, properties: [:]) })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            cursor = CursorProbe(image: blue, hotSpot: .zero); sampler.sampleNow()
            cursor = CursorProbe(image: blue, hotSpot: CGPoint(x: 2, y: 3)); sampler.sampleNow()
            cursor = nil; sampler.sampleNow(); sampler.sampleNow()
            cursor = CursorProbe(image: red, hotSpot: .zero); sampler.sampleNow()
            try require(samples.count == 5 && samples.allSatisfy(\.shapeChanged) && samples[3].image == nil,
                        "Known/unknown or hotspot changes did not produce explicit shape updates")
            try require(encodes == 3 && samples[4].image?.png == samples[0].image?.png, "Recently used cursor shape was not cached")
        }

        run("Failed PNG encoding is throttled and can recover without cursor movement") {
            let cursor = CursorProbe(image: try image(), hotSpot: .zero)
            var now: TimeInterval = 0, encodes = 0, samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), cursorProvider: { cursor }, locationProvider: { CGPoint(x: 100, y: 100) },
                screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                pngEncoder: { bitmap in
                    encodes += 1
                    return encodes == 1 ? nil : bitmap.representation(using: .png, properties: [:])
                }, clock: { now })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            for _ in 0..<20 { sampler.sampleNow() }
            try require(encodes == 1 && samples.count == 1 && samples[0].image == nil, "Encoding failure caused repeated PNG work at polling rate")
            now = 1; sampler.sampleNow()
            try require(encodes == 2 && samples.count == 2 && samples[1].shapeChanged && samples[1].image != nil,
                        "Transient encoding failure never recovered for a stationary cursor")
        }

        run("Large backing rasters are capped while logical geometry stays unchanged") {
            let source = try image(width: 512, height: 256, logicalSize: CGSize(width: 256, height: 128))
            var sample: HostCursorSample?
            let sampler = HostCursorSampler(display: display(), cursorProvider: { CursorProbe(image: source, hotSpot: CGPoint(x: 200, y: 80)) },
                locationProvider: { CGPoint(x: 3, y: 4) }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
            sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
            guard let raster = sample?.image else { throw CursorSamplerCheckFailure("No bounded large cursor") }
            try require(raster.pixelWidth == 256 && raster.pixelHeight == 128 && raster.logicalWidth == 256 && raster.logicalHeight == 128,
                        "Pixel cap changed the logical cursor size or aspect ratio")
            try require(raster.hotSpotX == 200 && raster.hotSpotY == 80, "Pixel cap guessed a new logical hotspot")
        }

        run("Invalid image dimensions, hotspots and encoder output become unknown") {
            let valid = try image()
            let cursors: [NSCursor] = [
                CursorProbe(image: NSImage(size: CGSize(width: 257, height: 10)), hotSpot: .zero),
                CursorProbe(image: NSImage(size: .zero), hotSpot: .zero),
                CursorProbe(image: valid, hotSpot: CGPoint(x: -1, y: 2)),
                CursorProbe(image: valid, hotSpot: CGPoint(x: CGFloat.infinity, y: 2)),
                CursorProbe(image: valid, hotSpot: CGPoint(x: 17, y: 2))
            ]
            for cursor in cursors {
                var sample: HostCursorSample?
                let sampler = HostCursorSampler(display: display(), cursorProvider: { cursor }, locationProvider: { CGPoint(x: 1, y: 1) },
                    screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
                sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
                try require(sample?.image == nil && sample?.shapeChanged == true, "Invalid cursor image or hotspot was advertised")
            }
            for payload: Data? in [nil, Data([1, 2, 3]), Data(count: 256 * 1024 + 1)] {
                var sample: HostCursorSample?
                let sampler = HostCursorSampler(display: display(), cursorProvider: { CursorProbe(image: valid, hotSpot: .zero) },
                    locationProvider: { CGPoint(x: 1, y: 1) }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) },
                    pngEncoder: { _ in payload })
                sampler.onSample = { sample = $0 }; sampler.start(); sampler.stop()
                try require(sample?.image == nil, "Invalid/oversized PNG escaped the raster boundary")
            }
        }

        run("Display updates emit fresh shape and mapped position") {
            let cursor = CursorProbe(image: try image(), hotSpot: .zero)
            var samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), cursorProvider: { cursor }, locationProvider: { CGPoint(x: -500, y: 400) },
                screenFrameProvider: { id in id == 1 ? CGRect(x: 0, y: 0, width: 1440, height: 900) : CGRect(x: -1000, y: 0, width: 1000, height: 800) })
            sampler.onSample = { samples.append($0) }; sampler.start(); defer { sampler.stop() }
            sampler.updateDisplay(display(2, bounds: CGRect(x: -1000, y: 100, width: 1000, height: 800)))
            try require(samples.count == 2 && !samples[0].insideDisplay && samples[1].insideDisplay && samples[1].x == 0.5 && samples[1].y == 0.5,
                        "Display update retained coordinates from the old display")
            try require(samples[1].shapeChanged && samples[1].image != nil, "New display did not receive its initial shape snapshot")
        }

        run("Stop fences timer polls, emits no hidden state and supports restart") {
            var reads = 0, samples: [HostCursorSample] = []
            let sampler = HostCursorSampler(display: display(), interval: 0.01, cursorProvider: { reads += 1; return nil },
                locationProvider: { CGPoint(x: 10, y: 20) }, screenFrameProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })
            sampler.onSample = { samples.append($0) }; sampler.start(); sampler.start(); drain()
            try require(reads > 1 && samples.count == 1, "Timer did not poll or emitted identical unknown state repeatedly")
            sampler.stop(); let previousReads = reads; let previousSamples = samples.count
            sampler.sampleNow(); drain()
            try require(reads == previousReads && samples.count == previousSamples, "Stopped sampler polled or fabricated a hide update")
            sampler.start(); sampler.stop()
            try require(samples.count == 2 && samples[1].shapeChanged, "Restart did not emit a new initial observation")
        }

        print("Cursor sampler checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
