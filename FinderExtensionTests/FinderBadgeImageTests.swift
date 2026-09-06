import AppKit
import XCTest
@testable import SvnDockFinderExtension

final class FinderBadgeImageTests: XCTestCase {
    func testEveryStateProducesVisibleStandardAndRetinaBitmaps() throws {
        for spec in FinderBadgeSymbolSpec.all {
            let image = try makeImage(spec)
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertTrue(!image.isTemplate)
            let bitmaps = try representations(of: image)
            XCTAssertEqual(bitmaps.map(\.pixelsWide), [16, 32])
            var visibleCounts: [Int] = []
            for bitmap in bitmaps {
                XCTAssertEqual(bitmap.pixelsHigh, bitmap.pixelsWide)
                XCTAssertEqual(bitmap.size, image.size)
                XCTAssertTrue(bitmap.hasAlpha)
                let pixels = try samples(bitmap)
                let visible = pixels.filter { $0.alpha > 0.01 }.count
                XCTAssertTrue(visible > bitmap.pixelsWide * bitmap.pixelsHigh / 10)
                XCTAssertTrue(visible < bitmap.pixelsWide * bitmap.pixelsHigh)
                for index in [0, bitmap.pixelsWide - 1,
                              (bitmap.pixelsHigh - 1) * bitmap.pixelsWide, pixels.count - 1] {
                    XCTAssertTrue(pixels[index].alpha < 0.01)
                }
                visibleCounts.append(visible)
            }
            // A nominal 2x representation with unscaled 1x pixels stays at the
            // same coverage. This catches the bitmap-context scaling pitfall.
            XCTAssertTrue(Double(visibleCounts[1]) > Double(visibleCounts[0]) * 2.5)
            XCTAssertTrue(Double(visibleCounts[1]) < Double(visibleCounts[0]) * 5)
        }
    }

    func testFilledStatesKeepWhiteGlyphsAndTheirStateColor() throws {
        for spec in FinderBadgeSymbolSpec.all where spec.symbol.hasSuffix(".fill") {
            let pixels = try samples(retinaBitmap(spec))
            XCTAssertTrue(pixels.contains { $0.isWhite })
            XCTAssertTrue(pixels.filter { $0.alpha > 0.5 && $0.matches(spec.color) }.count > 40)
        }
    }

    func testUnknownOutlineRemainsGrayWithoutWhiteFill() throws {
        let spec = try specification(FinderBadgeIdentifier.unknown)
        let pixels = try samples(retinaBitmap(spec))
        XCTAssertTrue(!pixels.contains { $0.isWhite })
        XCTAssertTrue(pixels.filter { $0.alpha > 0.5 && $0.matches(.gray) }.count > 40)
    }

    func testFilledStatesRemainDistinguishableWhenColorsMatch() throws {
        var masks = Set<Data>()
        for identifier in [FinderBadgeIdentifier.clean, FinderBadgeIdentifier.modified, FinderBadgeIdentifier.added] {
            let existing = try specification(identifier)
            let sameColor = FinderBadgeSymbolSpec(identifier: existing.identifier,
                symbol: existing.symbol, label: existing.label, color: .green)
            let pixels = try samples(retinaBitmap(sameColor))
            let mask = Data(pixels.map { $0.isWhite ? 1 : 0 })
            XCTAssertTrue(mask.contains(1))
            masks.insert(mask)
        }
        XCTAssertEqual(masks.count, 3)
    }

    func testSecureArchivePreservesBitmapSizesAndPixels() throws {
        for spec in FinderBadgeSymbolSpec.all {
            let source = try makeImage(spec)
            let data = try NSKeyedArchiver.archivedData(withRootObject: source, requiringSecureCoding: true)
            guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data) else {
                throw BadgeImageTestFailure(message: "Secure archive did not contain an image")
            }
            XCTAssertEqual(decoded.size, source.size)
            XCTAssertTrue(!decoded.isTemplate)
            let originalBitmaps = try representations(of: source)
            let decodedBitmaps = try representations(of: decoded)
            XCTAssertEqual(decodedBitmaps.map(\.pixelsWide), originalBitmaps.map(\.pixelsWide))
            for (original, restored) in zip(originalBitmaps, decodedBitmaps) {
                XCTAssertEqual(original.size, restored.size)
                XCTAssertEqual(try pixelData(original), try pixelData(restored))
            }
        }
    }

    func testTIFFPreservesTransparentColoredBitmapContent() throws {
        for spec in FinderBadgeSymbolSpec.all {
            let source = try makeImage(spec)
            guard let data = source.tiffRepresentation, let decoded = NSImage(data: data) else {
                throw BadgeImageTestFailure(message: "Badge has no decodable TIFF data")
            }
            let originalBitmaps = try representations(of: source)
            let decodedBitmaps = try representations(of: decoded)
            XCTAssertEqual(decodedBitmaps.map(\.pixelsWide), originalBitmaps.map(\.pixelsWide))
            for (original, restored) in zip(originalBitmaps, decodedBitmaps) {
                XCTAssertEqual(original.size, restored.size)
                XCTAssertEqual(try pixelData(original), try pixelData(restored))
            }
        }
    }

    func testUnavailableSymbolDoesNotProduceABlankBadge() {
        let invalid = FinderBadgeSymbolSpec(identifier: "Unavailable",
            symbol: "svndock.nonexistent.test.symbol", label: "Unavailable", color: .green)
        XCTAssertNil(FinderBadgeImages.image(for: invalid))
    }

    func testRenderingPreservesTheCallingGraphicsContext() throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw BadgeImageTestFailure(message: "Could not create the test graphics context")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        _ = try makeImage(specification(FinderBadgeIdentifier.clean))
        XCTAssertTrue(NSGraphicsContext.current === context)
    }

    private func specification(_ identifier: String) throws -> FinderBadgeSymbolSpec {
        guard let spec = FinderBadgeSymbolSpec.all.first(where: { $0.identifier == identifier }) else {
            throw BadgeImageTestFailure(message: "Missing badge specification")
        }
        return spec
    }

    private func makeImage(_ spec: FinderBadgeSymbolSpec) throws -> NSImage {
        guard let image = FinderBadgeImages.image(for: spec) else {
            throw BadgeImageTestFailure(message: "Could not render \(spec.identifier)")
        }
        return image
    }

    private func representations(of image: NSImage) throws -> [NSBitmapImageRep] {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .sorted { $0.pixelsWide < $1.pixelsWide }
        guard bitmaps.count == 2, bitmaps.count == image.representations.count else {
            throw BadgeImageTestFailure(message: "Image must contain only its 1x and 2x bitmap representations")
        }
        return bitmaps
    }

    private func retinaBitmap(_ spec: FinderBadgeSymbolSpec) throws -> NSBitmapImageRep {
        try representations(of: makeImage(spec))[1]
    }

    private func samples(_ bitmap: NSBitmapImageRep) throws -> [Pixel] {
        var pixels: [Pixel] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    throw BadgeImageTestFailure(message: "Bitmap contains an unreadable pixel")
                }
                pixels.append(Pixel(red: color.redComponent, green: color.greenComponent,
                                    blue: color.blueComponent, alpha: color.alphaComponent))
            }
        }
        return pixels
    }

    private func pixelData(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(try samples(bitmap).flatMap { pixel in
            [pixel.red, pixel.green, pixel.blue, pixel.alpha].map {
                UInt8(max(0, min(255, ($0 * 255).rounded())))
            }
        })
    }
}

private struct BadgeImageTestFailure: Error {
    let message: String
}

private struct Pixel {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var isWhite: Bool { alpha > 0.5 && min(red, green, blue) > 0.9 }

    func matches(_ color: FinderBadgeColor) -> Bool {
        switch color {
        case .green: green > red + 0.2 && green > blue + 0.2
        case .yellow: red > 0.6 && green > 0.5 && blue < 0.3
        case .red: red > green + 0.3 && red > blue + 0.3
        case .blue: blue > red + 0.3 && blue > green + 0.2
        case .gray: max(red, green, blue) - min(red, green, blue) < 0.1
            && red > 0.2 && red < 0.85
        }
    }
}
