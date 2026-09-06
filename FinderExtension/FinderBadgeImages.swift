import AppKit

/// Materializes badge pixels before handing an image to another process.
/// Finder still controls the badge's placement and display size.
enum FinderBadgeImages {
    static func image(for spec: FinderBadgeSymbolSpec) -> NSImage? {
        let color: NSColor
        switch spec.color {
        case .green: color = .systemGreen
        case .yellow: color = .systemYellow
        case .red: color = .systemRed
        case .blue: color = .systemBlue
        case .gray: color = .systemGray
        }
        // A one-color palette also paints the foreground of a filled symbol,
        // hiding its checkmark, plus, pencil or warning inside the background.
        let palette: [NSColor] = spec.symbol.hasSuffix(".fill") ? [.white, color] : [color]
        guard let symbol = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: palette)),
            symbol.size.width > 0, symbol.size.height > 0 else { return nil }
        symbol.isTemplate = false

        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.isTemplate = false
        image.accessibilityDescription = spec.label
        for scale in [1, 2] {
            guard let bitmap = bitmap(for: symbol, size: size, scale: scale) else { return nil }
            image.addRepresentation(bitmap)
        }
        return image
    }

    private static func bitmap(for symbol: NSImage, size: NSSize, scale: Int) -> NSBitmapImageRep? {
        let pixelsWide = Int(size.width) * scale
        let pixelsHigh = Int(size.height) * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size
        // A calibrated space survives TIFF/secure archiving with its colors.
        // Untagged device RGB is reinterpreted when AppKit decodes an image.

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        // Bitmap contexts use pixel coordinates; setting the representation's
        // point size alone does not scale drawing for a Retina representation.
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.imageInterpolation = .high
        let factor = min(size.width / symbol.size.width, size.height / symbol.size.height)
        let symbolSize = NSSize(width: symbol.size.width * factor, height: symbol.size.height * factor)
        let rect = NSRect(x: (size.width - symbolSize.width) / 2, y: (size.height - symbolSize.height) / 2,
                          width: symbolSize.width, height: symbolSize.height)
        symbol.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high])
        context.flushGraphics()
        return bitmap
    }
}
