import Foundation
import CoreImage
import Metal
import ImageIO

// Streaming average of one second of the empty screen. Two private textures
// bound memory independently of capture frame rate, and retain linear HDR data.
final class VideoEffectCleanPlate {
    private let renderer:MetalEffectRenderer
    private var textures:[MTLTexture]=[]
    private var index=0
    private var firstTime:Double?
    private var lastTime:Double?
    private var hdr:Bool?
    private(set) var count=0
    private(set) var progress=0.0
    private(set) var image:CIImage?
    init(renderer:MetalEffectRenderer) { self.renderer=renderer }
    enum Failure:LocalizedError {
        case orientation,interrupted,format
        var errorDescription:String? { switch self {
        case .orientation:return "The camera orientation changed. Capture the empty screen again."
        case .interrupted:return "Capture was interrupted. Capture the empty screen again."
        case .format:return "The camera format changed. Capture the empty screen again."
        } }
    }
    static func compatible(_ plate:CGSize,with frame:CGSize)->Bool {
        guard plate.width>0,plate.height>0,frame.width>0,frame.height>0 else{return false}
        return abs((plate.width/plate.height)/(frame.width/frame.height)-1)<0.01
    }
    private static let sizeLock=NSLock()
    nonisolated(unsafe) private static var sizes:[URL:CGSize]=[:]
    static func size(at url:URL)->CGSize? {
        sizeLock.lock();defer {sizeLock.unlock()}
        if let size=sizes[url] {return size}
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Double,let height=properties[kCGImagePropertyPixelHeight] as? Double else{return nil}
        let size=CGSize(width:width,height:height)
        if sizes.count>128 {sizes.removeAll()};sizes[url]=size
        return size
    }
    static func importedPNG(_ data:Data,matching size:CGSize?=nil) throws -> Data {
        guard let image=CIImage(data:data,options:[.applyOrientationProperty:true]) else { throw ProjectError.missingImage }
        if let size,!compatible(image.extent.size,with:size) {
            throw NSError(domain:"CleanPlate",code:1,userInfo:[NSLocalizedDescriptionKey:"This image does not match the video framing. Choose an empty-screen frame from the same camera orientation and aspect ratio."])
        }
        guard let png=CIContext().pngRepresentation(of:image,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else {throw ProjectError.missingImage}
        return png
    }
    func append(_ input:CIImage,time:Double,hdr:Bool=false) throws -> Bool {
        if let lastTime,time-lastTime>0.25 || time<lastTime { throw Failure.interrupted }
        if let previous=self.hdr,previous != hdr { throw Failure.format }
        self.hdr=hdr;lastTime=time
        let bounds=input.extent
        if textures.isEmpty {
            textures=[try renderer.texture(width:Int(bounds.width),height:Int(bounds.height)),try renderer.texture(width:Int(bounds.width),height:Int(bounds.height))]
            firstTime=time
        }
        guard textures[0].width==Int(bounds.width),textures[0].height==Int(bounds.height) else { throw Failure.orientation }
        count += 1
        // Dissolve blends opaque linear values once. Scaling both RGB and
        // alpha with CIColorMatrix would multiply the contribution twice.
        let next=image.map { $0.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:input,kCIInputTimeKey:1/Double(count)]) } ?? input
        index=1-index
        renderer.context.render(MetalEffectRenderer.textureImage(next),to:textures[index],commandBuffer:nil,bounds:CGRect(origin:.zero,size:bounds.size),colorSpace:renderer.space)
        guard let stored=CIImage(mtlTexture:textures[index],options:[.colorSpace:renderer.space]) else { throw VideoEffectError.buffer }
        image=MetalEffectRenderer.textureImage(stored)
        progress=min(1,max(0,time-(firstTime ?? time)))
        return progress>=1 && count>=8
    }
    func save(to url:URL) throws {
        guard let image else { throw VideoEffectError.buffer }
        try renderer.context.writeTIFFRepresentation(of:image,to:url,format:.RGBAh,colorSpace:renderer.space,options:[:])
    }
}
