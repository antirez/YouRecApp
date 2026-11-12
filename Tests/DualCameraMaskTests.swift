import Foundation
import CoreImage

@main struct DualCameraMaskTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    static func main() throws {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for size in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
            let bounds = CGRect(origin: .zero, size: size), w = Int(size.width), h = Int(size.height)
            let first = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: bounds)
            let second = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
            for flipped in [false, true] {
                var layout = DualCameraLayout(); layout.mode = .diagonal; layout.diagonalFlipped = flipped
                let output = DualCameraMasks.composite(first: first, second: second, layout: layout, canvas: size)
                var pixels = [UInt8](repeating: 0, count: w*h*4)
                context.render(output, toBitmap: &pixels, rowBytes: w*4, bounds: bounds, format: .RGBA8, colorSpace: nil)
                for y in 0..<h { for x in 0..<w {
                    let point = CGPoint(x: Double(x)+0.5, y: Double(y)+0.5), i = (y*w+x)*4
                    try check(pixels[i+3] == 255, "Diagonal has no transparent holes")
                    let owners = (0..<2).filter { layout.contains(point, slot: $0, in: size) }
                    try check(owners.count == 1, "Each diagonal point belongs to exactly one gesture region")
                    if abs(layout.diagonalDistance(point, in: size)) > 3 {
                        try check(pixels[i+(owners[0] == 0 ? 0 : 2)] > 250, "Rendered triangle agrees with touch ownership: \(point) flip \(flipped) bytes \(Array(pixels[i..<i+4]))")
                    }
                } }
                let old = layout; layout.flipDiagonal(); layout.flipDiagonal()
                try check(layout == old, "Two taps restore the diagonal")
                let data = try JSONEncoder().encode(layout)
                let decoded = try JSONDecoder().decode(DualCameraLayout.self, from: data)
                try check(decoded == layout, "Diagonal persists")
            }
            var layout = DualCameraLayout(); layout.roundInset = true; layout.insetAspect = 2; layout.insetSize = 0.6
            for axis in [DualCameraLayout.InsetResizeAxis.width, .height, .proportional] {
                layout.resizeInset(scale: 1.1, axis: axis, canvas: size)
                let rect = layout.regions(in: size)[1]
                try check(rect.width == rect.height && bounds.contains(rect), "Every pinch preserves a bounded circle")
            }
            layout.resizeInset(scale: 100, axis: .proportional, canvas: size)
            let rect = layout.regions(in: size)[1]
            let clip = CGRect(x: rect.minX, y: size.height-rect.maxY, width: rect.width, height: rect.height)
            let output = DualCameraMasks.composite(first: first, second: second.cropped(to: clip), layout: layout, canvas: size)
            var pixels = [UInt8](repeating: 0, count: w*h*4)
            context.render(output, toBitmap: &pixels, rowBytes: w*4, bounds: bounds, format: .RGBA8, colorSpace: nil)
            for y in 0..<h { for x in 0..<w {
                let point = CGPoint(x: Double(x)+0.5, y: Double(y)+0.5), i = (y*w+x)*4
                let distance = hypot(point.x-rect.midX, point.y-rect.midY)-rect.width/2
                try check(pixels[i+3] == 255, "Circle leaves no transparent corner holes")
                if abs(distance) > 2 {
                    let inside = layout.contains(point, slot: 1, in: size)
                    try check(inside == (distance < 0), "Circular gesture boundary")
                    try check(pixels[i+(inside ? 2 : 0)] > 250, "Circular mask matches gesture boundary")
                }
            } }
            layout.roundInset = false; layout.constrain()
            let restored = layout.regions(in: size)[1]
            try check(restored.width > restored.height, "Rectangle shape retained after circle mode")
            for round in [false, true] {
                var expanded = DualCameraLayout(); expanded.roundInset = round
                expanded.resizeInset(scale: 100, axis: .proportional, canvas: size)
                let full = expanded.regions(in: size)[1]
                try check(abs(full.width-min(size.width, size.height)) < 1e-6 && full.width == full.height, "Square and circle can reach the entire shorter canvas edge")
                expanded.resizeInset(scale: 0.9, axis: .proportional, canvas: size)
                try check(abs(expanded.regions(in: size)[1].width-full.width*0.9) < 1e-6, "Shrink responds immediately after reaching maximum size")
            }
            var expanded = DualCameraLayout()
            expanded.resizeInset(scale: 100, axis: .width, canvas: size)
            expanded.resizeInset(scale: 100, axis: .height, canvas: size)
            expanded.constrain() // The camera persists/constrains every gesture update.
            let full = expanded.regions(in: size)[1]
            try check(abs(full.width-size.width)<1e-6 && abs(full.height-size.height)<1e-6 && bounds.contains(full), "Rectangle can cover the complete canvas")
            let stored = try JSONDecoder().decode(DualCameraLayout.self, from: JSONEncoder().encode(expanded))
            try check(stored == expanded, "Full-size rectangle survives persistence")
            let rotated = CGSize(width: size.height, height: size.width), before = expanded.regions(in: rotated)[1]
            try check(CGRect(origin: .zero, size: rotated).contains(before) && abs(before.width/before.height-full.width/full.height)<1e-6, "Rotation fits without stretching or extending beyond the canvas")
            expanded.resizeInset(scale: 0.9, axis: .proportional, canvas: rotated)
            try check(abs(expanded.regions(in: rotated)[1].width-before.width*0.9)<1e-6, "Pinch starts from the displayed size after rotating")
            var framing = DualCameraLayout.Framing(); framing.zoom = 2
            let face = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
            for _ in 0..<120 { framing = DualFaceFraming.follow(face, source: size, region: bounds, current: framing, elapsed: 1.0/30, target: CGPoint(x: 0.5, y: 0.25)) }
            let placed = DualCameraLayout.placement(source: size, region: bounds, framing: framing)
            try check(placed.minY+face.midY*placed.height < size.height*0.31, "Diagonal face following aims inside upper triangle")
        }
        print("PASS: diagonal/circle GPU masks, touch ownership, opacity, portrait/landscape, resizing, persistence and face framing")
    }
}
