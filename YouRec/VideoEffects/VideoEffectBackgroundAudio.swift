@preconcurrency import AVFoundation
import CryptoKit
import ObjectiveC

// The head advances during the overlap, rather than freezing on frame zero.
// Both the video decoder and audio composer use this exact looping clock.
struct EffectBackgroundLoop {
    let duration: Double
    var overlap: Double { min(0.2,duration/2) }
    var period: Double { duration-overlap }
    func phase(at time:Double)->(incoming:Double,outgoing:Double?,blend:Double) {
        let time=max(0,time),cycle=floor(time/period),phase=time-cycle*period
        return (phase,cycle>0 && phase<overlap ? period+phase : nil,min(1,phase/overlap))
    }
}

enum VideoEffectBackgroundAudio {
    private struct Item {
        var asset:AVAsset
        var track: AVAssetTrack
        var source: CMTimeRange
        let start: Double
        var duration: Double
        var envelope: AudioEnvelopeSegment
        let identity:String
    }
    static func append(project:Project,folder:URL,to composition:AVMutableComposition) async throws -> [AVAudioMixInputParameters] {
        var cache:[String:(AVAsset,AVAssetTrack,CMTimeRange,Double)]=[:],silent=Set<String>(),items:[Item]=[]
        let layout=project.edit.layout
        for placement in layout.placements {
            var pieceStart=placement.start
            for clip in placement.clip.playbackPieces {
                defer { pieceStart += clip.duration }
                let freeze=clip.frozenFrame,freezeEffect=clip.videoEffects?.first(where:{$0.kind == .freezeFrame})
                let freezeMode=freezeEffect?.choice("audio",at:clip.start) ?? "Continue"
                if freeze != nil && freezeMode=="Cut" { continue }
                let sourceStart=clip.start+(freeze?.offset ?? 0)
                for effect in clip.videoEffects ?? [] where effect.enabled && [.chromaKey,.autoBackground].contains(effect.kind) {
                    if freeze != nil && !(effect.start<=clip.start && effect.end>clip.start) { continue }
                    let lower=freeze == nil ? max(clip.start,effect.start) : sourceStart
                    let upper=freeze == nil ? min(clip.end,effect.end) : sourceStart+clip.duration
                    guard upper>lower else { continue }
                    // Discrete media/toggle keyframes split the source interval.
                    let keys=freeze != nil ? [] : effect.parameters.filter { ["media","background","backgroundAudio"].contains($0.id) }.flatMap { $0.keyframes.map(\.time) }
                    let bounds=Array(Set([lower,upper]+keys.filter { $0>lower && $0<upper })).sorted()
                    for (a,b) in zip(bounds,bounds.dropFirst()) {
                        let settingTime=freeze == nil ? a : clip.start
                        guard effect.toggle("backgroundAudio",at:settingTime),effect.choice("background",at:settingTime)=="Video",
                              case .media(let file)=effect.value("media",at:settingTime),let file,!silent.contains(file) else { continue }
                        if cache[file] == nil {
                            let asset=AVURLAsset(url:folder.appendingPathComponent(file))
                            guard let track=try await asset.loadTracks(withMediaType:.audio).first else { silent.insert(file);continue }
                            let duration=try await asset.load(.duration).seconds,range=try await track.load(.timeRange)
                            guard duration.isFinite,duration>0.001 else { throw ProjectError.invalidMedia }
                            cache[file]=(asset,track,range,duration)
                        }
                        guard let (asset,track,available,duration)=cache[file] else { continue }
                        let loop=EffectBackgroundLoop(duration:duration),localA=max(0,a-effect.start),localB=b-effect.start
                        let first=max(0,Int(floor(localA/loop.period))-1),last=Int(floor(localB/loop.period))
                        for cycle in first...last {
                            let origin=Double(cycle)*loop.period
                            let begin=max(localA,origin+available.start.seconds),end=min(localB,origin+min(duration,available.end.seconds))
                            guard end-begin>1.0/60000 else { continue }
                            let start=pieceStart+(effect.start+begin-sourceStart)/clip.rate,output=(end-begin)/clip.rate
                            let loopStart=pieceStart+(effect.start+origin-sourceStart)/clip.rate
                            let joins=layout.joins(for:placement),inJoin=joins.incoming,outJoin=joins.outgoing
                            var envelope=AudioEnvelopeSegment(start:start,end:start+output,fadeIn:0.008,fadeOut:0.008,
                                clipStart:loopStart,clipEnd:loopStart+duration/clip.rate,
                                transitionIn:cycle>0 ? loop.overlap/clip.rate : 0,transitionOut:loop.overlap/clip.rate,
                                inRamp:inJoin.transition == nil ? nil : inJoin.audioIn,
                                outRamp:outJoin.transition == nil ? nil : outJoin.audioOut,volume:pow(10,-18.0/20))
                            if let freeze,freezeMode=="Fade out over hold" {
                                let hold=max(0.001,freezeEffect?.number("hold",at:clip.start) ?? freeze.duration)
                                let from=freeze.offset+start-pieceStart
                                envelope.volume *= max(0,1-from/hold)
                                envelope.endVolume=pow(10,-18.0/20)*max(0,1-(from+output)/hold)
                            }
                            items.append(Item(asset:asset,track:track,source:CMTimeRange(start:TransitionRenderer.time(begin-origin),end:TransitionRenderer.time(end-origin)),start:start,duration:output,envelope:envelope,identity:file+effect.id.uuidString+"-\(cycle)"))
                        }
                    }
                }
            }
        }
        // Rate integration and parameter keyframes create composition pieces,
        // not audible edits. Keep the envelope continuous across those pieces.
        let groups=Dictionary(grouping:items.indices,by:{items[$0].identity})
        for indices in groups.values {
            let ordered=indices.sorted { items[$0].start<items[$1].start }
            for (a,b) in zip(ordered,ordered.dropFirst()) {
                if abs(items[a].start+items[a].duration-items[b].start)<0.0001 && abs(items[a].source.end.seconds-items[b].source.start.seconds)<0.0001 {
                    items[a].envelope.fadeOut=0;items[b].envelope.fadeIn=0
                }
            }
        }
        // Keep each loop cycle continuous through the time-pitch processor.
        // Scaled composition edits can re-prime spectral audio, even at 0.5 s.
        // The envelopes still follow the exact video clock sample by sample.
        var batches:[(item:Item,envelopes:[AudioEnvelopeSegment])]=[]
        for indices in groups.values {
            var chains:[[Item]]=[]
            for index in indices.sorted(by:{items[$0].start<items[$1].start}) {
                let item=items[index]
                if let last=chains.last?.last,
                   abs(last.start+last.duration-item.start)<0.0001,
                   abs(last.source.end.seconds-item.source.start.seconds)<0.0001 {chains[chains.count-1].append(item)}
                else {chains.append([item])}
            }
            for chain in chains {
                var item=chain[0]
                let slices=chain.map { EffectAudioRateSlice(start:$0.source.start.seconds,end:$0.source.end.seconds,duration:$0.duration) }
                item.duration=chain.reduce(0){$0+$1.duration}
                item.source.duration=chain.last!.source.end-item.source.start
                if EffectAudioRateRenderer.needsContinuousRender(slices),let url=(item.asset as? AVURLAsset)?.url {
                    let length=TransitionRenderer.time(item.start+item.duration)-TransitionRenderer.time(item.start)
                    let rendered=try await EffectAudioRateRenderer.shared.render(url:url,slices:slices,folder:folder,outputDuration:length,retainedBy:composition)
                    let asset=AVURLAsset(url:rendered)
                    guard let track=try await asset.loadTracks(withMediaType:.audio).first else {throw ProjectError.invalidMedia}
                    item.asset=asset;item.track=track;item.source=CMTimeRange(start:.zero,duration:length)
                }
                batches.append((item,chain.map(\.envelope)))
            }
        }
        var tracks:[AVMutableCompositionTrack]=[],ends:[Double]=[],envelopes:[[AudioEnvelopeSegment]]=[]
        for batch in batches.sorted(by: { $0.item.start<$1.item.start }) {
            let item=batch.item
            try Task.checkCancellation()
            let index:Int
            if let free=ends.firstIndex(where: { $0<=item.start+0.000001 }) { index=free }
            else {
                guard let track=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw ProjectError.invalidMedia }
                index=tracks.count;tracks.append(track);ends.append(0);envelopes.append([])
            }
            let start=TransitionRenderer.time(item.start),length=TransitionRenderer.time(item.start+item.duration)-start
            do { try EffectAudioInsertion.insert(item.source,of:item.track,into:tracks[index],at:start,duration:length,retime:abs(item.source.duration.seconds-length.seconds)>0.001) }
            catch { throw NSError(domain:"VideoEffectBackgroundAudio",code:1,userInfo:[NSLocalizedDescriptionKey:"Background sound could not be inserted at \(item.start)s (source \(item.source.start.seconds)...\(item.source.end.seconds)s).",NSUnderlyingErrorKey:error]) }
            ends[index]=item.start+item.duration;envelopes[index]+=batch.envelopes
        }
        return try tracks.enumerated().map { i,track in
            let mix=AVMutableAudioMixInputParameters(track:track);mix.audioTimePitchAlgorithm = .spectral
            mix.audioTapProcessor=try CutAudioEnvelope.make(segments:envelopes[i])
            AudioGainMix.register(mix, envelopes: envelopes[i]); return mix
        }
    }
}

// Absolute timeline endpoints can differ by a tick from a rounded duration.
// Never start the spectral time-pitch processor just to correct that tick.
// Pad/trim to the exact output boundary, including frozen audio and short tracks.
enum EffectAudioInsertion {
    static func insert(_ source:CMTimeRange,of input:AVAssetTrack,into output:AVMutableCompositionTrack,at start:CMTime,duration:CMTime,retime:Bool,available:CMTimeRange?=nil) throws {
        let sourceDuration=retime ? source.duration : CMTimeMinimum(source.duration,duration)
        let requested=CMTimeRange(start:source.start,duration:sourceDuration)
        let range=available.map {CMTimeRangeGetIntersection(requested,otherRange:$0)} ?? requested
        if range.duration.seconds>0 {try output.insertTimeRange(range,of:input,at:start+(range.start-source.start))}
        let end=start+(retime ? source.duration : duration)
        if output.timeRange.end<end {output.insertEmptyTimeRange(CMTimeRange(start:output.timeRange.end,end:end))}
        if retime,source.duration != duration {output.scaleTimeRange(CMTimeRange(start:start,duration:source.duration),toDuration:duration)}
    }
}

struct EffectAudioRateSlice:Codable {
    let start:Double,end:Double,duration:Double
    var rate:Double {(end-start)/duration}
}
// One continuous AVAudioUnitTimePitch instance per continuous source interval.
// Video keeps its accurate integration pieces; audio changes rate in 256-sample
// blocks (5.33 ms at 48 kHz) without restarting a phase-vocoder at every edit.
private final class EffectAudioRateLease {
    let url:URL
    init(_ url:URL) {self.url=url}
    deinit {let file=url;Task {await EffectAudioRateRenderer.shared.release(file)}}
}
private final class EffectAudioRateRetention {
    let leases:[EffectAudioRateLease]
    init(_ leases:[EffectAudioRateLease]) {self.leases=leases}
}
actor EffectAudioRateRenderer {
    static let shared=EffectAudioRateRenderer()
    private static var retentionKey:UInt8=0
    private static let retentionLock=NSLock()
    private var pins:[URL:Int]=[:]
    private var initialized=Set<URL>()
    private var pruneTimes:[URL:Double]=[:]
    nonisolated static func retainAudio(from source:AVMutableComposition,in target:AVMutableComposition) {
        retentionLock.lock();defer {retentionLock.unlock()}
        let sourceLeases=(objc_getAssociatedObject(source,&retentionKey) as? EffectAudioRateRetention)?.leases ?? []
        let old=(objc_getAssociatedObject(target,&retentionKey) as? EffectAudioRateRetention)?.leases ?? []
        objc_setAssociatedObject(target,&retentionKey,EffectAudioRateRetention(old+sourceLeases),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    private func retain(_ url:URL,in composition:AVMutableComposition?) {
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)
        guard let composition else {return}
        pins[url.standardizedFileURL.resolvingSymlinksInPath(),default:0]+=1
        Self.retentionLock.lock();defer {Self.retentionLock.unlock()}
        let old=(objc_getAssociatedObject(composition,&Self.retentionKey) as? EffectAudioRateRetention)?.leases ?? []
        objc_setAssociatedObject(composition,&Self.retentionKey,EffectAudioRateRetention(old+[EffectAudioRateLease(url)]),.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    fileprivate func release(_ url:URL) {
        let key=url.standardizedFileURL.resolvingSymlinksInPath()
        if let count=pins[key],count>1 {pins[key]=count-1}else {pins[key]=nil}
        prune(url.deletingLastPathComponent())
    }
    func trimCache(in projectFolder:URL) {
        let folder=ProjectCacheLocation.root(in:projectFolder,preferred:"cache").appendingPathComponent("speed-audio",isDirectory:true)
        pruneTimes[folder]=nil;prune(folder)
    }
    private func prune(_ folder:URL) {
        let now=ProcessInfo.processInfo.systemUptime
        guard now-(pruneTimes[folder] ?? -.infinity)>10 else {return};pruneTimes[folder]=now
        let files=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []
        let records=files.filter {$0.pathExtension=="caf" && $0.deletingPathExtension().lastPathComponent.count==64}.map { file -> (URL,Int,Date) in
            let info=try? file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]);return (file,info?.fileSize ?? 0,info?.contentModificationDate ?? .distantPast)
        }
        var bytes=records.reduce(0){$0+$1.1}
        for (file,size,_) in records.sorted(by:{$0.2<$1.2}) where bytes>500_000_000 && pins[file.standardizedFileURL.resolvingSymlinksInPath()]==nil {
            if (try? FileManager.default.removeItem(at:file)) != nil {bytes-=size}
        }
        if initialized.insert(folder).inserted {
            for file in files where file.pathExtension=="caf" && file.deletingPathExtension().lastPathComponent.count != 64 {try? FileManager.default.removeItem(at:file)}
        }
    }
    nonisolated static func needsContinuousRender(_ slices:[EffectAudioRateSlice])->Bool {
        guard let first=slices.first else {return false}
        return slices.contains {abs($0.rate-first.rate)>0.0001}
    }
    func render(url:URL,slices:[EffectAudioRateSlice],folder:URL,outputDuration:CMTime?=nil,retainedBy composition:AVMutableComposition?=nil) throws -> URL {
        try Task.checkCancellation()
        guard let first=slices.first,let last=slices.last else {throw ProjectError.invalidMedia}
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let duration=outputDuration ?? TransitionRenderer.time(slices.reduce(0){$0+$1.duration})
        let stem=url.deletingPathExtension().lastPathComponent
        let contentAddressed=url.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare("Cache") == .orderedSame && stem.count==64 && stem.allSatisfy(\.isHexDigit)
        let modified=contentAddressed ? 0 : values.contentModificationDate?.timeIntervalSince1970 ?? 0
        var identity=Data("continuous-pitch-v2-pcm48k-stereo-block256-overlap8-\(url.lastPathComponent)-\(values.fileSize ?? 0)-\(modified)-\(duration.value)-\(duration.timescale)".utf8)
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        identity.append(try encoder.encode(slices))
        let hash=SHA256.hash(data:identity).map {String(format:"%02x",$0)}.joined()
        let cache=ProjectCacheLocation.root(in:folder,preferred:"cache").appendingPathComponent("speed-audio",isDirectory:true)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let output=cache.appendingPathComponent(hash+".caf")
        if FileManager.default.fileExists(atPath:output.path) {retain(output,in:composition);prune(cache);return output}
        prune(cache)
        let temporary=cache.appendingPathComponent(UUID().uuidString+".caf")
        defer {try? FileManager.default.removeItem(at:temporary)}
        let aligned=cache.appendingPathComponent(UUID().uuidString+"-aligned.caf")
        defer {try? FileManager.default.removeItem(at:aligned)}
        try extract(url:url,range:CMTimeRange(start:TransitionRenderer.time(first.start),end:TransitionRenderer.time(last.end)),to:aligned)
        let input=try AVAudioFile(forReading:aligned,commonFormat:.pcmFormatFloat32,interleaved:false),format=input.processingFormat
        let engine=AVAudioEngine(),player=AVAudioPlayerNode(),pitch=AVAudioUnitTimePitch()
        engine.attach(player);engine.attach(pitch)
        engine.connect(player,to:pitch,format:format);engine.connect(pitch,to:engine.mainMixerNode,format:format)
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        pitch.pitch=0;pitch.overlap=8;pitch.rate=Float(first.rate)
        if input.length>0 {
            var cursor:Int64=0
            while cursor<input.length {
                let count=AVAudioFrameCount(min(Int64(UInt32.max),input.length-cursor))
                player.scheduleSegment(input,startingFrame:cursor,frameCount:count,at:nil);cursor+=Int64(count)
            }
        }
        engine.prepare();try engine.start();player.play()
        defer {player.stop();engine.stop()}
        guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096) else {throw ProjectError.invalidMedia}
        let total=Int64(ceil(duration.seconds*format.sampleRate))
        var starts=[0.0];for slice in slices {starts.append(starts.last!+slice.duration)}
        func source(at output:Double)->Double {
            var low=0,high=slices.count
            while low+1<high {let mid=(low+high)/2;if starts[mid]<=output {low=mid}else {high=mid}}
            return slices[low].start+min(slices[low].duration,max(0,output-starts[low]))*slices[low].rate
        }
        var written:Int64=0,retries=0
        do {
            var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
            let file=try AVAudioFile(forWriting:temporary,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
            while written<total {
                try Task.checkCancellation()
                let frames=AVAudioFrameCount(min(256,total-written)),a=Double(written)/format.sampleRate,b=Double(written+Int64(frames))/format.sampleRate
                pitch.rate=Float(min(32,max(1.0/32,(source(at:b)-source(at:a))/(b-a))))
                let status=try engine.renderOffline(frames,to:buffer)
                switch status {
                case .success,.insufficientDataFromInputNode:
                    guard buffer.frameLength>0 else {throw ProjectError.invalidMedia}
                    try file.write(from:buffer);written+=Int64(buffer.frameLength);retries=0
                case .cannotDoInCurrentContext:
                    retries+=1;if retries>8 {throw ProjectError.invalidMedia}
                case .error:throw ProjectError.invalidMedia
                @unknown default:throw ProjectError.invalidMedia
                }
            }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:temporary,to:output)
        retain(output,in:composition);prune(cache)
        return output
    }
    // AVAudioFile ignores edit lists in some .mov containers. Decode LPCM from
    // the asset's presentation timeline instead, preserving trim, AAC priming,
    // empty edits and short tracks. All stretch input is aligned stereo 48 kHz.
    private func extract(url:URL,range:CMTimeRange,to destination:URL) throws {
        let asset=AVURLAsset(url:url),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        var settings=format.settings;settings[AVLinearPCMIsNonInterleaved]=false
        let file=try AVAudioFile(forWriting:destination,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        let total=Int64(ceil(range.duration.seconds*48000));var written:Int64=0
        func write(_ samples:[Float],skip:Int=0) throws {
            let count=min(samples.count/2-skip,Int(total-written))
            guard count>0,let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count)) else {return}
            buffer.frameLength=AVAudioFrameCount(count)
            for n in 0..<count {for c in 0..<2 {buffer.floatChannelData![c][n]=samples[(n+skip)*2+c]}}
            try file.write(from:buffer);written+=Int64(count)
        }
        func silence(until end:Int64) throws {
            while written<min(total,end) {try Task.checkCancellation();try write([Float](repeating:0,count:Int(min(4096,min(total,end)-written))*2))}
        }
        if let track=asset.tracks(withMediaType:.audio).first {
            let available=CMTimeRangeGetIntersection(range,otherRange:CMTimeRange(start:.zero,duration:asset.duration))
            if available.duration.seconds>0 {
                let reader=try AVAssetReader(asset:asset)
                let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false])
                output.alwaysCopiesSampleData=false;reader.timeRange=available
                guard reader.canAdd(output) else {throw ProjectError.invalidMedia};reader.add(output)
                guard reader.startReading() else {throw reader.error ?? ProjectError.invalidMedia}
                defer {if reader.status == .reading {reader.cancelReading()}}
                while let sample=output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let timestamp=sample.presentationTimeStamp.seconds-range.start.seconds
                    guard timestamp.isFinite,let block=CMSampleBufferGetDataBuffer(sample) else {throw ProjectError.invalidMedia}
                    let target=Int64((timestamp*48000).rounded()),size=CMBlockBufferGetDataLength(block)
                    guard size>0 else {continue}
                    guard size.isMultiple(of:8) else {throw ProjectError.invalidMedia}
                    var data=[Float](repeating:0,count:size/4)
                    let result=data.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:size,destination:$0.baseAddress!)}
                    guard result==kCMBlockBufferNoErr else {throw ProjectError.invalidMedia}
                    try silence(until:max(0,target));try write(data,skip:min(data.count/2,Int(max(0,written-target))))
                }
                if reader.status == .failed {throw reader.error ?? ProjectError.invalidMedia}
            }
        }
        try silence(until:total)
    }

}
