import Foundation
import CoreImage
import CoreVideo
import Compression

struct CapturedMaskFrame: Codable {
    var time: Double
    var offset: UInt64
    var bytes: Int
    var width: Int
    var height: Int
}
struct EffectQualityFrame:Codable {
    var time:Double
    var quality:VideoEffectQuality
}
struct EffectQualityTrack:Codable {
    var frames:[EffectQualityFrame]=[]
    func quality(at time:Double)->VideoEffectQuality {
        var a=0,b=frames.count
        while a<b { let m=(a+b)/2;if frames[m].time<=time { a=m+1 } else { b=m } }
        return frames.isEmpty ? .full : frames[max(0,a-1)].quality
    }
}
struct CapturedEffectAnalysis: Codable {
    var version = 1
    var palettes: [UUID: EffectPaletteTrack] = [:]
    var masks: [CapturedMaskFrame] = []
    var autoBackgroundMasks:[CapturedMaskFrame]?
    var qualities:[UUID:EffectQualityTrack]?
    var subjects:EffectSubjectTrack?
    var maskFilter:String? // Stored masks are final; readers never filter twice.
    var autoBackgroundMotionAware:Bool? // Optional so older builds can still read captures.
    var temporalMattes:[UUID:CapturedMatteTrack]?
    var temporalMattesFinalized:Bool?
}
struct CapturedMatteChunk:Codable {
    let offset:UInt64
    let bytes:Int
    let count:Int
}
struct CapturedMatteTrack:Codable {
    var version=1
    var timescale=600
    var chunks:[CapturedMatteChunk]=[]
}
struct CapturedMatteSample:Sendable {
    let tick:Int64
    let reset:Bool
    var time:Double {Double(tick)/600}
}
// Small masks are losslessly compressed independently, allowing random access
// without decoding a whole take. This never touches full-resolution pixels.
final class EffectAnalysisWriter {
    let metadataName:String
    let dataName:String
    private let folder: URL
    private let handle: FileHandle
    private var analysis = CapturedEffectAnalysis()
    private var checkpointFrames = 0
    private let checkpointInterval:Int
    private var previousMask: CVPixelBuffer?
    private var previousAutoMask:CVPixelBuffer?
    private var pendingMattes:[UUID:[UInt64]]=[:]
    private var lastMatteTicks:[UUID:Int64]=[:]
    init(folder: URL,metadataName:String="effect-" + UUID().uuidString + ".json",dataName:String="effect-" + UUID().uuidString + ".bin",maskFilter:String?=nil,motionAwareAutoBackground:Bool=false,checkpointInterval:Int=60) throws {
        self.folder = folder;self.checkpointInterval=checkpointInterval
        self.metadataName=metadataName;self.dataName=dataName;analysis.maskFilter=maskFilter
        analysis.autoBackgroundMotionAware=motionAwareAutoBackground ? true : nil
        let file = folder.appendingPathComponent(dataName)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw ProjectError.missingMedia }
        handle = try FileHandle(forWritingTo: file)
        // A recipe can be saved before its first frame arrives. Even a take
        // interrupted immediately must have a readable, empty analysis file.
        try checkpoint()
    }
    deinit { try? handle.close() }
    func append(time: Double, palettes: [UUID: EffectPalette], mask: CVPixelBuffer?, autoBackgroundMask:CVPixelBuffer?=nil, qualities:[UUID:VideoEffectQuality]=[:],subject:EffectSubjectSample?=nil,temporalResets:[UUID:Bool]=[:]) throws {
        let temporalTick:Int64?
        if !temporalResets.isEmpty {
            guard time.isFinite,(0...604800).contains(time) else {throw ProjectError.invalidDocument}
            let tick=Int64((time*600).rounded())
            for id in temporalResets.keys {
                guard tick>(lastMatteTicks[id] ?? -1) else {throw ProjectError.invalidDocument}
            }
            temporalTick=tick
        } else {temporalTick=nil}
        if var subject,subject.valid {
            subject.time=time
            if analysis.subjects==nil { analysis.subjects=EffectSubjectTrack(stepwise:true) }
            if time>(analysis.subjects?.samples.last?.time ?? -.infinity) { analysis.subjects?.samples.append(subject) }
        }
        else if var previous=analysis.subjects?.samples.last,previous.lost != true,time>previous.time {
            previous.time=time;previous.lost=true;analysis.subjects?.samples.append(previous)
        }
        for (id,quality) in qualities {
            if analysis.qualities == nil { analysis.qualities=[:] }
            if analysis.qualities?[id] == nil { analysis.qualities?[id]=EffectQualityTrack() }
            if analysis.qualities?[id]?.frames.last?.quality != quality { analysis.qualities?[id]?.frames.append(EffectQualityFrame(time:time,quality:quality)) }
        }
        for (id, palette) in palettes {
            if analysis.palettes[id]?.frames.last?.palette != palette {
                if analysis.palettes[id] == nil { analysis.palettes[id] = EffectPaletteTrack(frames: []) }
                analysis.palettes[id]!.frames.append(EffectPaletteFrame(time: time, palette: palette))
            }
        }
        func store(_ mask:CVPixelBuffer) throws -> CapturedMaskFrame {
            let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask), stride = CVPixelBufferGetBytesPerRow(mask)
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(mask) else { throw VideoEffectError.unavailableMask }
            var bytes = Data(capacity: width*height)
            for row in 0..<height { bytes.append(base.advanced(by: row*stride).assumingMemoryBound(to: UInt8.self), count: width) }
            let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
            let offset = try handle.offset()
            try handle.write(contentsOf: compressed)
            return CapturedMaskFrame(time:time,offset:offset,bytes:compressed.count,width:width,height:height)
        }
        if let mask,previousMask !== mask {let frame=try store(mask);previousMask=mask;analysis.masks.append(frame)}
        if let autoBackgroundMask,previousAutoMask !== autoBackgroundMask {
            let frame=try store(autoBackgroundMask)
            previousAutoMask=autoBackgroundMask
            if analysis.autoBackgroundMasks==nil {analysis.autoBackgroundMasks=[]}
            analysis.autoBackgroundMasks?.append(frame)
        }
        // Publish accepted-frame ticks only after their image analysis is saved.
        // A failed append resets the live ring before any subsequent frame.
        if let tick=temporalTick {
            for (id,reset) in temporalResets {
                lastMatteTicks[id]=tick
                pendingMattes[id,default:[]].append(UInt64(tick) | (reset ? 1<<63 : 0))
                if pendingMattes[id]!.count>=64 {try flushMatte(id)}
            }
        }
        // Checkpoint analysis alongside the writer's fragmented raw movie.
        checkpointFrames += 1
        if checkpointInterval>0 && checkpointFrames.isMultiple(of:checkpointInterval) { try checkpoint() }
    }
    func discard() {
        try? handle.close()
        for name in [metadataName,dataName] { try? FileManager.default.removeItem(at:folder.appendingPathComponent(name)) }
    }
    private func flushMatte(_ id:UUID)throws {
        guard let ticks=pendingMattes[id],!ticks.isEmpty else {return}
        var bytes=Data(capacity:ticks.count*8)
        for tick in ticks {var value=tick.littleEndian;withUnsafeBytes(of:&value) {bytes.append(contentsOf:$0)}}
        let compressed=try (bytes as NSData).compressed(using:.lzfse) as Data
        let offset=try handle.offset();try handle.write(contentsOf:compressed)
        if analysis.temporalMattes==nil {analysis.temporalMattes=[:]}
        if analysis.temporalMattes?[id]==nil {analysis.temporalMattes?[id]=CapturedMatteTrack()}
        analysis.temporalMattes?[id]?.chunks.append(.init(offset:offset,bytes:compressed.count,count:ticks.count))
        pendingMattes[id]=[]
    }
    func checkpoint(finalized:Bool=false) throws {
        for id in Array(pendingMattes.keys) {try flushMatte(id)}
        if analysis.temporalMattes != nil {analysis.temporalMattesFinalized=finalized}
        try handle.synchronize()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(analysis).write(to: folder.appendingPathComponent(metadataName), options: .atomic)
    }
}
final class EffectAnalysisReader {
    let analysis: CapturedEffectAnalysis
    var hasMotionAwareAutoBackground:Bool {(analysis.autoBackgroundMotionAware==true || analysis.maskFilter=="auto-background-motion-v2") && !(analysis.autoBackgroundMasks?.isEmpty ?? true)}
    private var temporalMattes:[UUID:[CapturedMatteSample]]=[:]
    private var failedTemporalMattes=Set<UUID>()
    private var temporalSampleCount=0
    private let fileLength:Int
    private let handle: FileHandle?
    private var cached:[Bool:(Int,CIImage)]=[:]
    private var pixelCache:(CIImage,CVPixelBuffer)?
    private lazy var pixelContext=CIContext(options:[.cacheIntermediates:false])
    private var pixelPool:CVPixelBufferPool?
    private var pixelSize=CGSize.zero
    init(metadata: URL, data: URL?) throws {
        guard let size=try metadata.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=64_000_000 else { throw ProjectError.invalidDocument }
        analysis = try JSONDecoder().decode(CapturedEffectAnalysis.self, from: Data(contentsOf: metadata))
        guard analysis.version == 1,analysis.masks.count<=2_000_000,analysis.palettes.count<=100 else { throw ProjectError.invalidDocument }
        guard analysis.maskFilter==nil || ["motion-gated-ema-v1","auto-background-ema-v1","auto-background-motion-v2"].contains(analysis.maskFilter ?? "") else {throw ProjectError.invalidDocument}
        fileLength=try data?.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        var previous = -Double.infinity
        for frames in [analysis.masks,analysis.autoBackgroundMasks ?? []] {
            guard frames.count<=2_000_000 else {throw ProjectError.invalidDocument}
            previous = -.infinity
        for frame in frames {
            guard frame.time.isFinite,frame.time>=0,frame.time>previous,(1...1024).contains(frame.width),(1...1024).contains(frame.height),
                  frame.bytes>0,frame.bytes<2_000_000,frame.bytes<=fileLength,frame.offset<=UInt64(fileLength-frame.bytes) else { throw ProjectError.invalidDocument }
            previous=frame.time
        }
        }
        for track in analysis.palettes.values {
            guard track.frames.count<=2_000_000 else { throw ProjectError.invalidDocument }
            previous = -Double.infinity
            for frame in track.frames {
                guard frame.time.isFinite,frame.time>=0,frame.time>previous,(2...16).contains(frame.palette.colors.count),frame.palette.colors.allSatisfy(\.valid),
                      frame.palette.thresholds.count==frame.palette.colors.count-1,frame.palette.thresholds.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw ProjectError.invalidDocument }
                previous=frame.time
            }
        }
        guard analysis.subjects?.valid ?? true else { throw ProjectError.invalidDocument }
        guard (analysis.qualities?.count ?? 0)<=100 else { throw ProjectError.invalidDocument }
        for track in analysis.qualities?.values ?? Dictionary<UUID,EffectQualityTrack>().values {
            guard track.frames.count<=2_000_000 else { throw ProjectError.invalidDocument }
            previous = -.infinity
            for frame in track.frames {
                guard frame.time.isFinite,frame.time>=0,frame.time>previous else { throw ProjectError.invalidDocument };previous=frame.time
            }
        }
        handle = try data.map { try FileHandle(forReadingFrom: $0) }
    }
    // Optional replay data must never make a valid movie or its saved masks
    // unreadable. Readers are queue-confined, just like mask(at:).
    func temporalMatte(for id:UUID)->[CapturedMatteSample]? {
        if let cached=temporalMattes[id] {return cached}
        guard !failedTemporalMattes.contains(id),let track=analysis.temporalMattes?[id] else {return nil}
        do {
            guard (analysis.temporalMattes?.count ?? 0)<=100 else {throw ProjectError.invalidDocument}
            guard track.version==1,track.timescale==600,track.chunks.count<=100_000,let handle else {throw ProjectError.invalidDocument}
            var samples:[CapturedMatteSample]=[]
            for chunk in track.chunks {
                guard (1...64).contains(chunk.count),chunk.bytes>0,chunk.bytes<=2048,chunk.bytes<=fileLength,chunk.offset<=UInt64(fileLength-chunk.bytes) else {throw ProjectError.invalidDocument}
                guard temporalSampleCount+samples.count+chunk.count<=2_000_000 else {throw ProjectError.invalidDocument}
                try handle.seek(toOffset:chunk.offset)
                guard let compressed=try handle.read(upToCount:chunk.bytes),compressed.count==chunk.bytes else {throw ProjectError.missingMedia}
                var raw=Data(count:chunk.count*8)
                let count=raw.withUnsafeMutableBytes {out in compressed.withUnsafeBytes {input in
                    compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to:UInt8.self),out.count,input.baseAddress!.assumingMemoryBound(to:UInt8.self),input.count,nil,COMPRESSION_LZFSE)
                }}
                guard count==raw.count else {throw ProjectError.invalidDocument}
                for index in 0..<chunk.count {
                    let word=raw.withUnsafeBytes {UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:index*8,as:UInt64.self))}
                    let tick=Int64(word & ~(1<<63))
                    guard tick<=604800*600,tick>(samples.last?.tick ?? -1) else {throw ProjectError.invalidDocument}
                    samples.append(CapturedMatteSample(tick:tick,reset:word>>63 != 0))
                }
            }
            temporalSampleCount+=samples.count;temporalMattes[id]=samples
            return samples
        } catch {
            failedTemporalMattes.insert(id)
            NSLog("YouRec: ignoring invalid optional matte history %@ (%@)",id.uuidString,error.localizedDescription)
            return nil
        }
    }
    deinit { try? handle?.close() }
    func rawPixel(at time:Double) throws -> CVPixelBuffer? {
        guard let image=try mask(at:time) else {return nil}
        if let cached=pixelCache,cached.0 === image {return cached.1}
        if pixelSize != image.extent.size {
            let attributes:[String:Any]=[kCVPixelBufferWidthKey as String:Int(image.extent.width),kCVPixelBufferHeightKey as String:Int(image.extent.height),
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_OneComponent8,kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attributes as CFDictionary,&pixelPool)==kCVReturnSuccess else {throw VideoEffectError.buffer}
            pixelSize=image.extent.size
        }
        var pixel:CVPixelBuffer?
        guard let pixelPool,CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pixelPool,&pixel)==kCVReturnSuccess,let pixel else {throw VideoEffectError.buffer}
        pixelContext.render(image,to:pixel,bounds:image.extent,colorSpace:nil)
        pixelCache=(image,pixel);return pixel
    }
    func mask(at time: Double,autoBackground:Bool=false) throws -> CIImage? {
        let frames=autoBackground ? analysis.autoBackgroundMasks ?? [] : analysis.masks
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count
        while low < high { let mid = (low+high)/2; if frames[mid].time <= time { low=mid+1 } else { high=mid } }
        let index = max(0,low-1)
        if cached[autoBackground]?.0 == index { return cached[autoBackground]?.1 }
        let frame = frames[index]
        guard (1...1024).contains(frame.width), (1...1024).contains(frame.height), frame.bytes > 0, frame.bytes < 2_000_000, let handle else { throw ProjectError.invalidDocument }
        try handle.seek(toOffset: frame.offset)
        guard let data = try handle.read(upToCount: frame.bytes), data.count == frame.bytes else { throw ProjectError.missingMedia }
        var decoded=Data(count:frame.width*frame.height)
        let count=decoded.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in
            compression_decode_buffer(destination.baseAddress!.assumingMemoryBound(to:UInt8.self),destination.count,
                source.baseAddress!.assumingMemoryBound(to:UInt8.self),source.count,nil,COMPRESSION_LZFSE)
        } }
        guard count == frame.width*frame.height,
              let provider = CGDataProvider(data: decoded as CFData),
              let bitmap = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: frame.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ProjectError.invalidDocument }
        let image = CIImage(cgImage: bitmap, options: [.colorSpace: NSNull()]); cached[autoBackground] = (index,image); return image
    }
}


import AVFoundation
import CryptoKit
import Vision

struct EffectMaskChunk:Sendable {
    let start:Double
    let metadata:URL
    let data:URL
    var end:Double = .infinity
}
struct EffectMaskFiles:Sendable {
    let metadata:URL
    let data:URL
    var chunks:[EffectMaskChunk]=[]
    var isComplete=true
    func at(_ time:Double)->EffectMaskFiles? {
        guard !chunks.isEmpty else {return self}
        // A partially prepared timeline must never stretch a nearby mask across
        // an unanalysed gap. Use the provisional per-frame path in that gap.
        guard let part=chunks.last(where:{$0.start<=time && time<$0.end}) else {return nil}
        return EffectMaskFiles(metadata:part.metadata,data:part.data)
    }
}
// Fixed source-time chunks give random access without analysing a long source's
// entire prefix. Each chunk starts with the same two-second warm-up, regardless
// of seek order. Never carry state from a previously requested chunk.
actor EffectMaskAnalysis {
    static let shared=EffectMaskAnalysis()
    private var gate=VideoEffectAnalysisGate()
    static func directory(source: SourceMedia, folder: URL, captured: EffectMaskFiles?) throws -> URL {
        struct Key:Encodable {let source:SourceMedia;let version=5;let revision=VNGeneratePersonSegmentationRequest().revision;let compute="prefer-neural-engine";let captured:String?}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let key=SHA256.hash(data:try encoder.encode(Key(source:source,captured:captured?.metadata.lastPathComponent))).map {String(format:"%02x",$0)}.joined()
        return ProjectCacheLocation.root(in:folder,preferred:"cache").appendingPathComponent("masks/"+key,isDirectory:true)
    }
    func track(source:SourceMedia,folder:URL,range:ClosedRange<Double>?=nil,captured:EffectMaskFiles?=nil,generate:Bool=true) async throws -> EffectMaskFiles {
        let directory = try Self.directory(source: source, folder: folder, captured: captured)
        let lower=max(0,range?.lowerBound ?? 0),upper=min(source.duration,range?.upperBound ?? source.duration)
        let first=max(0,Int(floor(lower/10))),last=max(first,Int(floor(max(lower,upper-0.000001)/10)))
        let asset=AVURLAsset(url:folder.appendingPathComponent(source.filename))
        guard let video=try await asset.loadTracks(withMediaType:.video).first else {throw ProjectError.invalidMedia}
        let sourceSize=try await video.load(.naturalSize),preferred=try await video.load(.preferredTransform)
        let orientation = SourcePersonMasks.orientation(size: sourceSize, preferred: preferred)
        let descriptions=try await video.load(.formatDescriptions),hdr=descriptions.contains {VideoColor.isHDR($0)}
        let recorded=try captured.map {try EffectAnalysisReader(metadata:$0.metadata,data:$0.data)}
        if generate {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)}
        var parts:[EffectMaskChunk]=[]
        var complete=true
        for chunk in first...last {
            try Task.checkCancellation()
            let begin=Double(chunk)*10,end=min(source.duration,begin+10),warm=max(0,begin-2)
            let part=EffectMaskChunk(start:begin,metadata:directory.appendingPathComponent("c\(chunk).json"),data:directory.appendingPathComponent("c\(chunk).bin"),end:end)
            while true {
                try Task.checkCancellation()
                if generate && gate.mustWait(part.metadata.path,deferrable:VideoEffectPreparation.deferrable) {
                    try await Task.sleep(for:.milliseconds(100));continue
                }
                if let existing=try? EffectAnalysisReader(metadata:part.metadata,data:part.data),!existing.analysis.masks.isEmpty,!(existing.analysis.autoBackgroundMasks?.isEmpty ?? true) {parts.append(part);break}
                guard generate else {complete=false;break}
                guard let ticket=gate.claim(part.metadata.path,deferrable:VideoEffectPreparation.deferrable) else {
                    try await Task.sleep(for:.milliseconds(100));continue
                }
                defer {gate.release(ticket)}
                do {
                    let reader=try AVAssetReader(asset:asset)
                    let output=AVAssetReaderTrackOutput(track:video,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                    output.alwaysCopiesSampleData=false;reader.add(output)
                    reader.timeRange=CMTimeRange(start:CMTime(seconds:warm,preferredTimescale:60000),end:CMTime(seconds:end,preferredTimescale:60000))
                    guard reader.startReading() else {throw reader.error ?? ProjectError.invalidMedia}
                    defer {reader.cancelReading()}
                    let writer=try EffectAnalysisWriter(folder:directory,maskFilter:"auto-background-ema-v1",motionAwareAutoBackground:true,checkpointInterval:0)
                    defer {writer.discard()}
                    let provider=recorded==nil ? VideoEffectPersonProvider(live:false) : nil,smoother=try VideoEffectMaskSmoother()
                    var count=0
                    while let sample=output.copyNextSampleBuffer() {
                        try ticket.check();try Task.checkCancellation()
                        guard let pixel=sample.imageBuffer else {continue}
                        try autoreleasepool {
                            let time=sample.presentationTimeStamp.seconds,image=CIImage(cvPixelBuffer:pixel)
                            let raw:CVPixelBuffer
                            if let recorded,let saved=try recorded.rawPixel(at:time) {raw=saved}
                            else if let provider {raw=try provider.mask(image,stateless:true,orientation:orientation)}
                            else {throw VideoEffectError.unavailableMask}
                            let mask=try smoother.push(raw,image:image,time:time,geometry:source.filename,motionGate:true)
                            if time+0.000001>=begin && time<end {
                                try writer.append(time:time,palettes:[:],mask:raw,autoBackgroundMask:mask);count+=1
                            }
                        }
                        // Permit cache-only lookups from a scrub while a longer source
                        // is being analysed. All mutable providers above are task-local.
                        try await VideoEffectPreparation.checkpoint(ticket);await Task.yield()
                    }
                    guard reader.status == .completed,count>0 else {throw reader.error ?? ProjectError.invalidMedia}
                    try ticket.check();try writer.checkpoint()
                    // Another task may have finished this immutable chunk while this
                    // actor yielded. Keep the published files rather than replacing
                    // them under an active compositor's reader.
                    if let existing=try? EffectAnalysisReader(metadata:part.metadata,data:part.data),!existing.analysis.masks.isEmpty,!(existing.analysis.autoBackgroundMasks?.isEmpty ?? true) {parts.append(part);break}
                    for file in [part.metadata,part.data] where FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}
                    try FileManager.default.moveItem(at:directory.appendingPathComponent(writer.dataName),to:part.data)
                    try FileManager.default.moveItem(at:directory.appendingPathComponent(writer.metadataName),to:part.metadata)
                    parts.append(part);break
                } catch is VideoEffectAnalysisGate.Superseded {continue}
            }
        }
        guard let first=parts.first else {
            if generate {throw ProjectError.invalidMedia}
            throw VideoEffectError.analysisPending
        }
        return EffectMaskFiles(metadata:first.metadata,data:first.data,chunks:parts,isComplete:complete)
    }
}

// A render instruction describes the original camera geometry. Decoder, Vision
// and Metal state belong to the compositor using it, never to the project.
struct SourcePersonMasks {
    let url: URL
    let hdr: Bool
    let orientation: CGAffineTransform
    let cacheDirectory: URL
    let captured: EffectMaskFiles?
    // Interactive previews need only the requested frame. Final rendering visits
    // canonical source samples so export, trims and checkpoint resumes agree.
    enum Mode {
        case preview
        case paletteSample
        case export(VideoEffectFrameIndex)
    }
    var mode: Mode
    var finalFrames: VideoEffectFrameIndex? {
        if case .export(let index) = mode { return index }
        return nil
    }
    var identity: String {
        switch mode {
        case .preview: return cacheDirectory.path + "|preview"
        case .paletteSample: return cacheDirectory.path + "|palette"
        case .export: return cacheDirectory.path + "|final"
        }
    }
    var forPalette: Self {
        var copy = self
        copy.mode = .paletteSample
        return copy
    }

    static func orientation(size: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let upright = CGRect(origin: .zero, size: size).applying(preferred)
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            .concatenating(preferred).concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: upright.height))
    }
}

final class SourcePersonMaskReader {
    struct Frame {
        let raw: CIImage
        let background: CIImage
    }
    private let source: SourcePersonMasks
    private let provider: VideoEffectPersonProvider
    private let renderer: MetalEffectRenderer?
    private var smoother: VideoEffectMaskSmoother?
    private let captured: EffectAnalysisReader?
    private var reader: VideoEffectSourceReader?
    private var chunk: Int?
    private var disk: EffectAnalysisReader?
    private var previewFrame: (time: Double, frame: Frame)?
    private var lastIndex: Int?
    private var recent: [(Int, Frame)] = []

    init(_ source: SourcePersonMasks, renderer: MetalEffectRenderer? = nil) throws {
        self.source = source
        self.renderer = renderer
        if case .preview = source.mode { provider = VideoEffectPersonProvider(live: true) }
        else { provider = VideoEffectPersonProvider(live: false) }
        captured = try source.captured.map { try EffectAnalysisReader(metadata: $0.metadata, data: $0.data) }
    }

    private func original(at time: Double) throws -> CIImage {
        if reader == nil { reader = try VideoEffectSourceReader(url: source.url, hdr: source.hdr, capacity: 2, sourceMaskInput: true) }
        return try reader!.sample(at: time, firstAtOrAfter: source.finalFrames != nil).image
    }

    private func segment(_ image: CIImage, time: Double) throws -> Frame {
        let raw = try captured?.rawPixel(at: time) ?? provider.mask(image, stateless: true, orientation: source.orientation)
        let rawImage = CIImage(cvPixelBuffer: raw, options: [.colorSpace: NSNull()])
        // Palette clustering samples at 5 Hz. Segment only those samples and
        // keep them independent of the order in which the editor requested them.
        if case .paletteSample = source.mode { return Frame(raw: rawImage, background: rawImage) }
        let history = try smoother ?? VideoEffectMaskSmoother(renderer: renderer)
        smoother = history
        let alpha = try history.push(raw, image: image, time: time, geometry: source.url.path, motionGate: true)
        return Frame(raw: rawImage, background: CIImage(cvPixelBuffer: alpha, options: [.colorSpace: NSNull()]))
    }

    func frame(at time: Double, currentImage: CIImage?, cancelled: () -> Bool) throws -> Frame {
        let index = source.finalFrames?.last(at: time)
        let stamp = index.flatMap { source.finalFrames?.times[$0] } ?? time
        let part = max(0, Int(floor(stamp / 10)))
        if chunk != part {
            chunk = part
            lastIndex = nil
            previewFrame = nil
            recent.removeAll(keepingCapacity: true)
            smoother?.reset()
            let metadata = source.cacheDirectory.appendingPathComponent("c\(part).json")
            disk = FileManager.default.fileExists(atPath: metadata.path) ? try? EffectAnalysisReader(
                metadata: metadata, data: source.cacheDirectory.appendingPathComponent("c\(part).bin")) : nil
        }
        if cancelled() { throw CancellationError() }
        if let disk, disk.hasMotionAwareAutoBackground, let raw = try? disk.mask(at: stamp) {
            if case .paletteSample = source.mode { return Frame(raw: raw, background: raw) }
            if let background = try? disk.mask(at: stamp, autoBackground: true) {
                return Frame(raw: raw, background: background)
            }
            // This derived chunk is disposable. Rebuild its frames from source.
            self.disk = nil
        }
        guard let frames = source.finalFrames, let index else {
            if let previewFrame, previewFrame.time == stamp { return previewFrame.frame }
            let frame = try segment(currentImage ?? original(at: stamp), time: stamp)
            previewFrame = (stamp, frame)
            return frame
        }
        if let cached = recent.last(where: { $0.0 == index }) { return cached.1 }
        let start: Int
        if let lastIndex, lastIndex < index { start = lastIndex + 1 }
        else {
            // Same source-time origin and two-second warm-up as existing mask
            // chunks, independent of the preceding edit, seek or export section.
            smoother?.reset()
            recent.removeAll(keepingCapacity: true)
            start = min(index, frames.first(at: max(0, Double(part) * 10 - 2)))
        }
        for i in start...index {
            if cancelled() { throw CancellationError() }
            let frame = try autoreleasepool { try segment(original(at: frames.times[i]), time: frames.times[i]) }
            recent.append((i, frame))
            if recent.count > 8 { recent.removeFirst() }
            lastIndex = i
        }
        return recent[recent.count - 1].1
    }
}
