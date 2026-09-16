import AppKit
import SwiftUI

/// Wishper Pro's monochrome mark (`BrandMark.svg`, copied from logo.svg) as a template image:
/// luminance becomes alpha, so the black background disappears and the system tints the swirl.
enum BrandMark {
    /// Calibration knob: values below 1 lift the mid-greys so the swirl stays readable at 16–18 pt.
    static let gamma: CGFloat = 0.7

    @MainActor private static var cache: [CGFloat: NSImage] = [:]

    @MainActor
    static func image(pointSize: CGFloat) -> NSImage {
        if let cached = cache[pointSize] { return cached }
        let image = makeImage(pointSize: pointSize) ?? fallbackImage(pointSize: pointSize)
        cache[pointSize] = image
        return image
    }

    private static func makeImage(pointSize: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else { return nil }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [1, 2] as [CGFloat] {
            guard let cgImage = templateCGImage(svg: svg, pixels: Int(pointSize * scale)) else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    private static func templateCGImage(svg: NSImage, pixels: Int) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        var proposed = bounds
        guard let raster = svg.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let gray = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        gray.interpolationQuality = .high
        gray.draw(raster, in: bounds)
        if let luminance = gray.data?.assumingMemoryBound(to: UInt8.self) {
            for index in 0..<(pixels * pixels) {
                luminance[index] = UInt8((pow(CGFloat(luminance[index]) / 255, gamma) * 255).rounded())
            }
        }
        guard let mask = gray.makeImage(),
              let output = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        output.clip(to: bounds, mask: mask)
        output.setFillColor(CGColor(gray: 0, alpha: 1))
        output.fill(bounds)
        return output.makeImage()
    }

    /// Used when the SVG isn't in the bundle (e.g. `swift build` binary) or can't be loaded.
    private static func fallbackImage(pointSize: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize * 0.8, weight: .medium)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wishper Pro")?
            .withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        return image
    }
}

struct BrandMarkView: View {
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: BrandMark.image(pointSize: size))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
