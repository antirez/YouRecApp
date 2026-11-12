import Foundation
import CoreImage
import Vision

// All coordinates are normalized, top-down, in the recorded frame. Keeping the
// coordinate convention explicit avoids mirrored previews changing the target.
struct EffectSubjectSample:Codable,Equatable,Sendable {
    var time:Double
    var box:CGRect
    var confidence:Float
    var face:Bool
    var lost:Bool? // Explicit gaps keep recorded tracking identical on replay.
    var center:CGPoint { CGPoint(x:box.midX,y:box.midY) }
    var clipped:Bool { box.minX<0.015 || box.minY<0.015 || box.maxX>0.985 || box.maxY>0.985 }
    var valid:Bool {
        time.isFinite && (0...604800).contains(time) && confidence.isFinite && (0...1).contains(confidence)
            && [box.minX,box.minY,box.width,box.height].allSatisfy(\.isFinite)
            && box.width>0 && box.height>0 && box.minX>=0 && box.minY>=0 && box.maxX<=1.0001 && box.maxY<=1.0001
    }
}
struct EffectSubjectTrack:Codable,Sendable {
    var samples:[EffectSubjectSample]=[]
    var stepwise:Bool? // Captured samples describe the exact target used for each rendered frame.
    var valid:Bool { samples.count<=2_000_000 && samples.allSatisfy(\.valid) && zip(samples,samples.dropFirst()).allSatisfy {$0.time<$1.time} }
    func sample(at time:Double)->EffectSubjectSample? {
        var a=0,b=samples.count
        while a<b { let m=(a+b)/2;if samples[m].time<=time { a=m+1 } else { b=m } }
        guard a>0 else { return nil }
        let previous=samples[a-1]
        guard previous.lost != true,time-previous.time<=0.5 else { return nil }
        if stepwise == true { return previous }
        guard a<samples.count,samples[a].lost != true,samples[a].time-previous.time<=0.5 else { return previous }
        let next=samples[a],fraction=min(1,max(0,(time-previous.time)/(next.time-previous.time)))
        var result=previous;result.time=time
        result.box=CGRect(x:previous.box.minX+(next.box.minX-previous.box.minX)*fraction,
                          y:previous.box.minY+(next.box.minY-previous.box.minY)*fraction,
                          width:previous.box.width+(next.box.width-previous.box.width)*fraction,
                          height:previous.box.height+(next.box.height-previous.box.height)*fraction)
        return result
    }
}

// Queue-confined. Detection periodically corrects drift; object tracking fills
// the intervening frames without measuring the already-zoomed effect output.
final class EffectSubjectTracker {
    private let handler=VNSequenceRequestHandler()
    private var observation:VNDetectedObjectObservation?
    private var previous:EffectSubjectSample?
    private var lastDetection = -Double.infinity
    private var face=true
    private let point:CGPoint?
    private let live:Bool
    init(point:CGPoint?=nil,live:Bool) { self.point=point;self.live=live }
    private static func topDown(_ rect:CGRect)->CGRect { CGRect(x:rect.minX,y:1-rect.maxY,width:rect.width,height:rect.height) }
    private static func overlap(_ a:CGRect,_ b:CGRect)->Double {
        let intersection=a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width*intersection.height/max(0.000001,a.width*a.height+b.width*b.height-intersection.width*intersection.height)
    }
    func update(_ input:CIImage,time:Double) throws -> EffectSubjectSample? {
        let scale=min(1,512/max(input.extent.width,input.extent.height))
        let image=input.transformed(by:CGAffineTransform(translationX:-input.extent.minX,y:-input.extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        if time-lastDetection>=0.5 || observation==nil {
            lastDetection=time
            let faces=VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(ciImage:image,options:[:]).perform([faces])
            var candidates:[(VNDetectedObjectObservation,Bool)]=(faces.results ?? []).filter {$0.confidence>=0.5}.map { ($0,true) }
            if candidates.isEmpty {
                let people=VNDetectHumanRectanglesRequest();people.upperBodyOnly=false
                try VNImageRequestHandler(ciImage:image,options:[:]).perform([people])
                candidates=(people.results ?? []).filter {$0.confidence>=0.5}.map { ($0,false) }
            }
            let chosen:(VNDetectedObjectObservation,Bool)?
            if let previous,time-previous.time<0.5 {
                chosen=candidates.filter {$0.1==previous.face && Self.overlap(Self.topDown($0.0.boundingBox),previous.box)>0.1}
                    .max { Self.overlap(Self.topDown($0.0.boundingBox),previous.box)<Self.overlap(Self.topDown($1.0.boundingBox),previous.box) }
            } else if let point {
                chosen=candidates.min { a,b in
                    let aa=Self.topDown(a.0.boundingBox),bb=Self.topDown(b.0.boundingBox)
                    if aa.contains(point) != bb.contains(point) { return aa.contains(point) }
                    return hypot(aa.midX-point.x,aa.midY-point.y)<hypot(bb.midX-point.x,bb.midY-point.y)
                }
            } else { chosen=candidates.max {$0.0.boundingBox.width*$0.0.boundingBox.height < $1.0.boundingBox.width*$1.0.boundingBox.height} }
            if let chosen { observation=chosen.0;face=chosen.1 }
        }
        guard let observation else { return nil }
        let request=VNTrackObjectRequest(detectedObjectObservation:observation)
        request.trackingLevel=live ? .fast : .accurate
        try handler.perform([request],on:image)
        guard let tracked=request.results?.first as? VNDetectedObjectObservation,tracked.confidence>=0.5 else { self.observation=nil;return nil }
        self.observation=tracked
        let box=Self.topDown(tracked.boundingBox).intersection(CGRect(x:0,y:0,width:1,height:1))
        var result=EffectSubjectSample(time:time,box:box,confidence:tracked.confidence,face:face)
        guard result.valid else { self.observation=nil;return nil }
        if let previous,time>previous.time,time-previous.time<0.5,previous.face==face {
            let alpha=1-exp(-(time-previous.time)/0.12)
            let center=CGPoint(x:previous.center.x+(result.center.x-previous.center.x)*alpha,y:previous.center.y+(result.center.y-previous.center.y)*alpha)
            result.box.origin=CGPoint(x:center.x-box.width/2,y:center.y-box.height/2)
        }
        result.box=result.box.intersection(CGRect(x:0,y:0,width:1,height:1))
        previous=result;return result
    }
}

import AVFoundation
import CryptoKit

actor EffectSubjectAnalysis {
    static let shared=EffectSubjectAnalysis()
    private var gate=VideoEffectAnalysisGate()
    private var cached:[String:EffectSubjectTrack]=[:]
    func track(source:SourceMedia,effect:VideoEffectSettings,clip:TimelineClip,folder:URL,generate:Bool=true) async throws -> EffectSubjectTrack {
        struct Key:Encodable { let source:SourceMedia;let start:Double;let end:Double;let x:Double;let y:Double;let version=2 }
        let start=max(clip.start,effect.start),end=min(clip.end,effect.end)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let seed=CGPoint(x:effect.number("targetX",at:start),y:effect.number("targetY",at:start))
        let key=SHA256.hash(data:try encoder.encode(Key(source:source,start:start,end:end,x:seed.x,y:seed.y))).map { String(format:"%02x",$0) }.joined()
        while true {
            try Task.checkCancellation()
            if generate && gate.mustWait(key,deferrable:VideoEffectPreparation.deferrable) {
                try await Task.sleep(for:.milliseconds(100));continue
            }
            if let track=cached[key] { return track }
            let directory=ProjectCacheLocation.root(in:folder,preferred:"cache"),url=directory.appendingPathComponent("subject-\(key).json")
            if let data=try? Data(contentsOf:url),let track=try? JSONDecoder().decode(EffectSubjectTrack.self,from:data),track.valid { VideoEffectAnalysisFiles.touched(url);cached[key]=track;return track }
            guard generate else {throw VideoEffectError.analysisPending}
            guard let ticket=gate.claim(key,deferrable:VideoEffectPreparation.deferrable) else {
                try await Task.sleep(for:.milliseconds(100));continue
            }
            defer {gate.release(ticket)}
            do {
                let asset=AVURLAsset(url:folder.appendingPathComponent(source.filename))
                guard let video=try await asset.loadTracks(withMediaType:.video).first else { throw ProjectError.invalidMedia }
                let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:video,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
                output.alwaysCopiesSampleData=false;reader.add(output)
                reader.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),end:CMTime(seconds:end,preferredTimescale:60000))
                guard reader.startReading() else { throw reader.error ?? ProjectError.invalidMedia };defer { reader.cancelReading() }
                let tracker=EffectSubjectTracker(point:seed,live:false)
                var result=EffectSubjectTrack(),next=start
                while let sample=output.copyNextSampleBuffer() {
                    try ticket.check();try Task.checkCancellation()
                    let time=max(start,sample.presentationTimeStamp.seconds)
                    guard time+0.00001>=next,let pixel=sample.imageBuffer else { continue }
                    next=time+1.0/15
                    try autoreleasepool { if let target=try tracker.update(CIImage(cvPixelBuffer:pixel),time:time) { result.samples.append(target) } }
                    try await VideoEffectPreparation.checkpoint(ticket);await Task.yield()
                }
                if reader.status == .failed { throw reader.error ?? ProjectError.invalidMedia }
                try ticket.check()
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                try encoder.encode(result).write(to:url,options:.atomic)
                VideoEffectAnalysisFiles.prune(in:directory,keeping:url)
                if cached.count>=8 { cached.removeAll() };cached[key]=result;return result
            } catch is VideoEffectAnalysisGate.Superseded {continue}
        }
    }
}
