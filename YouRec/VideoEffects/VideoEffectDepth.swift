@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
#if canImport(Cinematic)
import Cinematic
#endif

// Depth remains in the original imported movie. This descriptor is a derived
// cache, not project state: archives and Undo already retain that source file.
struct VideoEffectDepthStamp:Equatable,Sendable {
    let value:Int64
    let timescale:Int32
    var time:CMTime {CMTime(value:value,timescale:timescale)}
    var seconds:Double {Double(value)/Double(timescale)}
}
struct VideoEffectDepthSource:@unchecked Sendable {
    let asset:AVURLAsset
    let track:AVAssetTrack
    let videoTrackID:CMPersistentTrackID
    let range:CMTimeRange
    let frameDuration:Double
    let videoSize:CGSize
    let depthSize:CGSize
    let videoTransform:CGAffineTransform
    let depthTransform:CGAffineTransform
    var metadataTrack:AVAssetTrack?
    var readFocus:((CMSampleBuffer)->Float?)?
    var frames:[VideoEffectDepthStamp]=[]
    var lower:Float=0
    var upper:Float=1
    let identity:String
    var aligned:Bool {
        guard videoSize.width>0,videoSize.height>0,depthSize.width>0,depthSize.height>0,
              abs(videoSize.width/videoSize.height-depthSize.width/depthSize.height)<0.01 else {return false}
        func normal(_ size:CGSize,_ transform:CGAffineTransform)->CGAffineTransform {
            let bounds=CGRect(origin:.zero,size:size).applying(transform)
            return CGAffineTransform(scaleX:size.width,y:size.height).concatenating(transform)
                .concatenating(CGAffineTransform(translationX:-bounds.minX,y:-bounds.minY))
                .concatenating(CGAffineTransform(scaleX:1/bounds.width,y:1/bounds.height))
        }
        let a=normal(videoSize,videoTransform),b=normal(depthSize,depthTransform)
        return zip([a.a,a.b,a.c,a.d,a.tx,a.ty],[b.a,b.b,b.c,b.d,b.tx,b.ty]).allSatisfy {abs($0-$1)<0.0001}
    }
    // Missing more than two frames disables depth for the selected interval;
    // never alternate depth and segmentation abruptly inside that interval.
    func covers(_ interval:ClosedRange<Double>)->Bool {
        guard let first=frames.first?.seconds,let last=frames.last?.seconds,interval.lowerBound>=first-0.000001,interval.upperBound<=min(range.end.seconds,last+frameDuration)+0.000001 else {return false}
        return !zip(frames,frames.dropFirst()).contains {a,b in
            b.seconds-a.seconds>frameDuration*2+0.000001 && a.seconds+frameDuration<interval.upperBound && b.seconds>interval.lowerBound
        }
    }
}
actor VideoEffectDepthCatalog {
    static let shared=VideoEffectDepthCatalog()
    private struct Entry {let source:VideoEffectDepthSource?}
    private var cache:[String:Entry]=[:]
    func source(url:URL,generate:Bool=true) async throws -> VideoEffectDepthSource? {
        let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let key=url.path+"|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        try Task.checkCancellation()
        if let entry=cache[key] {return entry.source}
        guard generate else {throw VideoEffectError.analysisPending}
        var source:VideoEffectDepthSource?
        #if canImport(Cinematic)
        if #available(iOS 17.0,macOS 14.0,*) {
            let asset=AVURLAsset(url:url)
            let cinematic=await CNAssetInfo.isCinematic(asset:asset)
            try Task.checkCancellation()
            if cinematic {
                do {
                    let info=try await CNAssetInfo(asset:asset),track=info.cinematicDisparityTrack
                    let range=try await track.load(.timeRange),fps=try await info.cinematicVideoTrack.load(.nominalFrameRate)
                    let videoSize=try await info.cinematicVideoTrack.load(.naturalSize),depthSize=try await track.load(.naturalSize)
                    let videoTransform=try await info.cinematicVideoTrack.load(.preferredTransform),depthTransform=try await track.load(.preferredTransform)
                    if range.start.seconds.isFinite,range.duration.seconds.isFinite,range.duration.seconds>0 {
                        var candidate=VideoEffectDepthSource(asset:asset,track:track,videoTrackID:info.cinematicVideoTrack.trackID,range:range,frameDuration:1/max(1,Double(fps)),videoSize:videoSize,depthSize:depthSize,videoTransform:videoTransform,depthTransform:depthTransform,identity:key+"|cinematic-disparity-v2|\(track.trackID)")
                        if let attributes=try? await CNRenderingSession.Attributes(asset:asset) {
                            candidate.metadataTrack=info.cinematicMetadataTrack
                            candidate.readFocus={CNRenderingSession.FrameAttributes(sampleBuffer:$0,sessionAttributes:attributes)?.focusDisparity}
                        }
                        // Advertise depth only when the actual decoder works,
                        // rather than trusting a track label or metadata alone.
                        candidate.frames=try Self.index(asset:asset,track:track)
                        let reader=VideoEffectDepthReader(source:candidate)
                        var samples:[Float]=[],attempted=0
                        // One immutable robust range per source. Per-frame
                        // normalisation would make the blur visibly breathe.
                        let count=min(32,candidate.frames.count)
                        for index in 0..<count {
                            try Task.checkCancellation()
                            let t=candidate.frames[index*max(0,candidate.frames.count-1)/max(1,count-1)].seconds
                            if let pixel=try reader.pixel(at:t) {let grid=Self.samples(pixel);samples.append(contentsOf:grid.values);attempted+=grid.attempted}
                            try await VideoEffectPreparation.checkpoint();await Task.yield()
                        }
                        if let range=Self.normalization(samples,attempted:attempted) {candidate.lower=range.lowerBound;candidate.upper=range.upperBound;source=candidate}
                    }
                } catch is CancellationError {throw CancellationError()} catch {NSLog("YouRec: imported depth is unavailable: %@",error.localizedDescription);return nil}
            }
        }
        #endif
        try Task.checkCancellation()
        let bytes=(source?.frames.count ?? 0)*MemoryLayout<VideoEffectDepthStamp>.stride
        if cache.count>=32 || cache.values.reduce(bytes,{$0+($1.source?.frames.count ?? 0)*MemoryLayout<VideoEffectDepthStamp>.stride})>32*1024*1024 {cache.removeAll()}
        if bytes<=32*1024*1024 {cache[key]=Entry(source:source)}
        return source
    }
    static func normalization(_ values:[Float],attempted:Int)->ClosedRange<Float>? {
        let sorted=values.filter {$0.isFinite}.sorted()
        guard !sorted.isEmpty,sorted.count>=max(1,attempted/10) else {return nil}
        let low=sorted[Int(Double(sorted.count-1)*0.02)],high=sorted[Int(Double(sorted.count-1)*0.98)]
        guard high-low>=max(0.001,0.05*max(abs(low),abs(high))) else {return nil}
        return low...high
    }
    private static func samples(_ pixel:CVPixelBuffer)->(values:[Float],attempted:Int) {
        CVPixelBufferLockBaseAddress(pixel,.readOnly);defer {CVPixelBufferUnlockBaseAddress(pixel,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(pixel) else {return ([],0)}
        let width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel),row=CVPixelBufferGetBytesPerRow(pixel)
        var values:[Float]=[],attempted=0
        for y in stride(from:0,to:height,by:max(1,height/36)) {
            let line=base.advanced(by:y*row).assumingMemoryBound(to:UInt16.self)
            for x in stride(from:0,to:width,by:max(1,width/64)) {
                attempted+=1
                let value=Float(Float16(bitPattern:line[x]));if value.isFinite {values.append(value)}
            }
        }
        return (values,attempted)
    }
    private static func index(asset:AVAsset,track:AVAssetTrack) throws -> [VideoEffectDepthStamp] {
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderSampleReferenceOutput(track:track)
        guard reader.canAdd(output) else {throw ProjectError.invalidMedia};reader.add(output)
        output.alwaysCopiesSampleData=false
        guard reader.startReading() else {throw reader.error ?? ProjectError.invalidMedia}
        defer {reader.cancelReading()}
        var times:[VideoEffectDepthStamp]=[]
        while let sample=output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard sample.numSamples>0 else {continue}
            if let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]],attachments.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool==true {continue}
            let time=CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard time.seconds.isFinite,time.timescale>0,time.epoch==0,times.count<3_000_000 else {throw ProjectError.invalidMedia}
            if time.seconds>=0 {times.append(.init(value:time.value,timescale:time.timescale))}
        }
        guard reader.status == .completed,!times.isEmpty else {throw reader.error ?? ProjectError.invalidMedia}
        times.sort {$0.seconds<$1.seconds}
        var result:[VideoEffectDepthStamp]=[]
        for time in times where result.last?.seconds != time.seconds {result.append(time)}
        return result
    }
}

// Queue-confined to the owning compositor/analysis renderer. Retains only the
// displayed and next small disparity buffers; reverse seeks reopen the reader.
// A missing depth interval is missing, never an arbitrarily stretched old map.
final class VideoEffectDepthReader {
    let source:VideoEffectDepthSource
    private struct Frame {let time:Double;let duration:Double;let pixel:CVPixelBuffer}
    private var reader:AVAssetReader?
    private var output:AVAssetReaderTrackOutput?
    private var current:Frame?,next:Frame?
    private var metadataOutput:AVAssetReaderTrackOutput?
    private var focusCurrent:(time:Double,duration:Double,value:Float)?,focusNext:(time:Double,duration:Double,value:Float)?
    private var lastRequest:Double?
    init(source:VideoEffectDepthSource) {self.source=source}
    deinit {reader?.cancelReading()}
    private func reset(at time:Double) throws {
        reader?.cancelReading();current=nil;next=nil;focusCurrent=nil;focusNext=nil;metadataOutput=nil
        let reader=try AVAssetReader(asset:source.asset)
        let output=AVAssetReaderTrackOutput(track:source.track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_DisparityFloat16,kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else {throw ProjectError.invalidMedia};reader.add(output)
        var a=0,b=source.frames.count
        while a<b {let m=(a+b)/2;if source.frames[m].seconds<=time+0.000001 {a=m+1}else {b=m}}
        // Starting at an indexed presentation timestamp avoids AVAssetReader
        // relabelling a held frame with an arbitrary mid-frame range start.
        let start=source.frames.isEmpty ? source.range.start : source.frames[max(0,a-1)].time
        if let track=source.metadataTrack {
            let metadata=AVAssetReaderTrackOutput(track:track,outputSettings:nil)
            metadata.alwaysCopiesSampleData=false
            if reader.canAdd(metadata) {reader.add(metadata);metadataOutput=metadata}
        }
        reader.timeRange=CMTimeRange(start:start,end:source.range.end)
        guard reader.startReading() else {throw reader.error ?? ProjectError.invalidMedia}
        self.reader=reader;self.output=output
        next=try read();focusNext=readFocus()
    }
    private func read() throws -> Frame? {
        while let sample=output?.copyNextSampleBuffer() {
            guard let pixel=sample.imageBuffer else {continue}
            guard CVPixelBufferGetPixelFormatType(pixel)==kCVPixelFormatType_DisparityFloat16 else {throw ProjectError.invalidMedia}
            let time=sample.presentationTimeStamp.seconds,duration=sample.duration.seconds
            guard time.isFinite else {throw ProjectError.invalidMedia}
            return Frame(time:time,duration:duration.isFinite && duration>0 ? duration : source.frameDuration,pixel:pixel)
        }
        if reader?.status == .failed {throw reader?.error ?? ProjectError.invalidMedia}
        return nil
    }
    private func readFocus()->(time:Double,duration:Double,value:Float)? {
        while let sample=metadataOutput?.copyNextSampleBuffer() {
            let t=sample.presentationTimeStamp.seconds,d=sample.duration.seconds
            if let value=source.readFocus?(sample),value.isFinite,t.isFinite {
                return (t,d.isFinite && d>0 ? d : source.frameDuration,value)
            }
        }
        return nil
    }
    // Stream metadata alongside disparity, retaining two samples, rather than
    // materialising a whole movie's Cinematic script just to find focus.
    private func focus(at time:Double)->Float? {
        while let frame=focusNext,frame.time<=time+0.000001 {focusCurrent=frame;focusNext=readFocus()}
        guard let frame=focusCurrent,time>=frame.time-0.000001,time<frame.time+max(frame.duration,source.frameDuration*2)+0.000001 else {return nil}
        return min(1,max(0,(frame.value-source.lower)/(source.upper-source.lower)))
    }
    func pixel(at time:Double) throws -> CVPixelBuffer? {
        guard time.isFinite,time>=source.range.start.seconds-0.000001,time<source.range.end.seconds else {return nil}
        if reader==nil || lastRequest.map({time<$0-0.000001 || time-$0>0.5})==true {try reset(at:time)}
        lastRequest=time
        while let frame=next,frame.time<=time+0.000001 {current=frame;_ = focus(at:frame.time);next=try read()}
        guard let frame=current,time>=frame.time-0.000001,time<frame.time+max(frame.duration,source.frameDuration*2)+0.000001 else {return nil}
        return frame.pixel
    }
    func sample(at time:Double) throws -> (pixel:CVPixelBuffer,focus:Float?)? {
        guard let pixel=try pixel(at:time) else {return nil}
        return (pixel,focus(at:time))
    }
    func image(at time:Double) throws -> CIImage? {
        try pixel(at:time).map {CIImage(cvPixelBuffer:$0,options:[.colorSpace:NSNull()])}
    }
}
