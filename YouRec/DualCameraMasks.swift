import CoreImage
import CoreImage.CIFilterBuiltins

/// GPU masks shared by the actual preview/recording compositor and pixel tests.
enum DualCameraMasks {
    private static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = foreground; filter.backgroundImage = background; filter.maskImage = mask
        return filter.outputImage!
    }
    static func composite(first: CIImage, second: CIImage, layout: DualCameraLayout, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        if layout.mode == .diagonal {
            // Core Image is bottom-up. A one-pixel ramp antialiases each edge
            // of the two-pixel separator; the normal is aspect-ratio aware.
            let length = hypot(1/canvas.width, 1/canvas.height)
            let normal = CGPoint(x: (layout.diagonalFallsRight ? -1 : 1)/canvas.width/length, y: -1/canvas.height/length)
            func mask(at offset: CGFloat) -> CIImage {
                let filter = CIFilter.linearGradient()
                filter.point0 = CGPoint(x: canvas.width/2+normal.x*(offset-0.5), y: canvas.height/2+normal.y*(offset-0.5))
                filter.point1 = CGPoint(x: canvas.width/2+normal.x*(offset+0.5), y: canvas.height/2+normal.y*(offset+0.5))
                filter.color0 = .white; filter.color1 = .black
                return filter.outputImage!.cropped(to: bounds)
            }
            let separator = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: bounds)
            let upper = blend(first, over: separator, mask: mask(at: -1))
            return blend(upper, over: second, mask: mask(at: 1)).cropped(to: bounds)
        }
        if layout.mode == .floating && layout.isRound {
            let region = layout.regions(in: canvas)[1], filter = CIFilter.radialGradient()
            filter.center = CGPoint(x: region.midX, y: canvas.height-region.midY)
            filter.radius0 = Float(max(0, region.width/2-0.5)); filter.radius1 = Float(region.width/2+0.5)
            filter.color0 = .white; filter.color1 = .black
            // Apply coverage to the inset first, then source-over the full
            // frame. Fractional crop edges must not reduce the canvas alpha.
            let inset = blend(second, over: CIImage.empty(), mask: filter.outputImage!)
            return inset.composited(over: first).cropped(to: bounds)
        }
        return second.composited(over: first)
    }
}
