import SwiftUI
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import ImageIO

private func coverTimestamp(_ time: EditTime) -> String {
    let hundredths = Int((time.seconds * 100).rounded())
    return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
}

extension AVAssetImageGenerator {
    convenience init(editorAsset asset: AVAsset, composition: AVVideoComposition?) {
        self.init(asset: asset)
        appliesPreferredTrackTransform = true
        videoComposition = composition
        requestedTimeToleranceBefore = .zero
        requestedTimeToleranceAfter = .zero
        if #available(iOS 18.0, *) { dynamicRangePolicy = .forceSDR }
    }
}

/// Capture the editor's assembled picture once. The grid and JPEG then use
/// the same composition and clock even if a pending effect finishes later.
final class CoverPickerSource: Hashable {
    private let asset: AVAsset
    private let composition: AVVideoComposition?
    let pool: CoverFramePool
    let title: String
    let scopeLabel: String
    let rangeLabel: String
    let aspect: CGFloat

    init(item: AVPlayerItem, project: Project, selection: TimelineSelection, canvas: CGSize) {
        asset = item.asset
        composition = item.videoComposition
        title = project.title
        aspect = canvas.width > 0 && canvas.height > 0 ? canvas.width / canvas.height : 16.0 / 9.0
        let timeline = project.edit.timeline
        let scope: [EditInterval]
        if let range = selection.range {
            scope = [range]; scopeLabel = "Selected range"
        } else if !selection.isEmpty {
            scope = timeline.video.filter { selection.video.contains($0.id) }.map(\.interval)
                + timeline.audio.filter { selection.audio.contains($0.id) }.map(\.interval)
            scopeLabel = "Selected clips"
        } else {
            scope = [EditInterval(.zero, timeline.duration)]; scopeLabel = "Whole project"
        }
        rangeLabel = coverTimestamp(scope.map(\.start).min() ?? .zero) + " – " + coverTimestamp(scope.map(\.end).max() ?? .zero)
        var picture = timeline.video.map(\.interval)
        // A Still transition can extend the outgoing picture beyond its clip.
        for join in timeline.transitions where join.settings.style == .still && join.outgoing != nil {
            let timing = TransitionTiming(join.settings, factor: join.factor, edge: join.incoming == nil ? 1 : 0)
            picture.append(EditInterval(join.origin, min(timeline.duration, join.origin + EditTime(timing.videoDuration))))
        }
        let frame = item.videoComposition?.frameDuration.seconds ?? 0
        pool = CoverFramePool(picture: picture, scope: scope, frameDuration: EditTime(frame.isFinite && frame > 0 ? frame : 1.0 / 30))
    }

    func generator(thumbnail: Bool) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(editorAsset: asset, composition: composition)
        if thumbnail { generator.maximumSize = CGSize(width: 512, height: 512) }
        return generator
    }

    static func == (lhs: CoverPickerSource, rhs: CoverPickerSource) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private struct CoverJPEG: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .suggestedFileName { $0.filename }
    }

    static func encode(_ image: CGImage, title: String, time: EditTime) async throws -> Self {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        let separators = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let name = title.components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = coverTimestamp(time).replacingOccurrences(of: ":", with: "-")
        return Self(data: data as Data, filename: String((name.isEmpty ? "YouRec" : name).prefix(40)) + " - " + timestamp + ".jpg")
    }
}

struct CoverPicker: View {
    let source: CoverPickerSource
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picks: [Int] = []
    @State private var thumbnails: [Int: CGImage] = [:]
    @State private var failures: Set<Int> = []
    @State private var selected: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.scopeLabel).font(.subheadline.weight(.semibold))
                    Text(source.rangeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { update() } label: {
                    Label("Update", systemImage: "arrow.clockwise").frame(minHeight: 44)
                }.buttonStyle(.bordered).tint(.white).disabled(source.pool.count <= 9)
                    .accessibilityHint("Show other frames from the same range.")
                    .accessibilityIdentifier("cover.update")
            }.padding(.horizontal).padding(.vertical, 4)
            if source.pool.count == 0 {
                ContentUnavailableView("No video in this range", systemImage: "film", description: Text("Select a range that contains video."))
            } else {
                ScrollView {
                    let minimum: CGFloat = typeSize.isAccessibilitySize ? 170 : (source.aspect < 1 ? 100 : 148)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 10)], spacing: 15) {
                        ForEach(picks, id: \.self) { pick in
                            let stamp = coverTimestamp(source.pool.time(of: pick))
                            Button { selected = pick } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Color(white: 0.09).aspectRatio(source.aspect, contentMode: .fit)
                                        .overlay {
                                            if let image = thumbnails[pick] {
                                                Image(decorative: image, scale: 1).resizable().scaledToFit()
                                            } else if failures.contains(pick) {
                                                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                                            } else { ProgressView() }
                                        }.clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(stamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Frame at " + stamp)
                                .accessibilityIdentifier("cover.frame.\(pick)")
                        }
                    }.padding(.horizontal).padding(.vertical, 10)
                }
            }
        }.background(Color.black).navigationTitle("Select cover").navigationBarTitleDisplayMode(.inline)
            .onAppear { if picks.isEmpty { update() } }
            .task(id: picks) { await loadThumbnails(for: picks) }
            .navigationDestination(item: $selected) { pick in
                CoverDetail(source: source, initialPick: pick, thumbnail: thumbnails[pick]).id(pick)
            }
    }

    private func update() {
        let next = source.pool.picks(replacing: picks)
        thumbnails = thumbnails.filter { next.contains($0.key) }
        failures = []
        picks = next
    }

    private func loadThumbnails(for batch: [Int]) async {
        guard !batch.isEmpty else { return }
        let generator = source.generator(thumbnail: true)
        await withTaskCancellationHandler {
            for pick in batch where thumbnails[pick] == nil {
                guard !Task.isCancelled else { return }
                do {
                    let result = try await generator.image(at: TrackRenderer.time(source.pool.time(of: pick)))
                    guard !Task.isCancelled, picks == batch else { return }
                    thumbnails[pick] = result.image
                } catch {
                    guard !Task.isCancelled, picks == batch else { return }
                    failures.insert(pick)
                }
            }
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }
}

private struct CoverDetail: View {
    let source: CoverPickerSource
    let initialPick: Int
    let thumbnail: CGImage?
    @State private var pick: Int
    @State private var dragStart: Int?
    @State private var frame: CGImage?
    @State private var renderedPick: Int?
    @State private var jpeg: (pick: Int, file: CoverJPEG)?
    @State private var failed = false

    init(source: CoverPickerSource, initialPick: Int, thumbnail: CGImage?) {
        self.source = source
        self.initialPick = initialPick
        self.thumbnail = thumbnail
        _pick = State(initialValue: initialPick)
    }

    private var time: EditTime { source.pool.time(of: pick) }
    private var sharePick: Int? { renderedPick == pick && dragStart == nil && !failed ? pick : nil }

    private func select(_ index: Int) {
        let next = min(source.pool.count - 1, max(0, index))
        guard next != pick else { return }
        pick = next
        failed = false
    }

    private func scrub(_ drag: DragGesture.Value) {
        let movement = drag.translation
        guard dragStart != nil || abs(movement.width) > abs(movement.height) else { return }
        let origin = dragStart ?? pick
        dragStart = origin
        // Swiping left reveals later frames. Fixed travel per frame and no
        // momentum keep the same gesture precise at every project length.
        select(origin - Int(movement.width / 24))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color(white: 0.07).aspectRatio(source.aspect, contentMode: .fit)
                .overlay {
                    if let picture = frame ?? (pick == initialPick ? thumbnail : nil) {
                        Image(picture, scale: 1, label: Text("Cover image")).resizable().scaledToFit()
                            .accessibilityValue("\(picture.width) × \(picture.height) pixels")
                            .accessibilityIdentifier("cover.image")
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6)
                    .onChanged(scrub)
                    .onEnded { value in scrub(value); dragStart = nil })
                .accessibilityHint("Swipe left for later frames or right for earlier frames.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: select(pick + 1)
                    case .decrement: select(pick - 1)
                    @unknown default: break
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let jpeg, jpeg.pick == sharePick, let frame {
                        ShareLink(item: jpeg.file, preview: SharePreview(jpeg.file.filename, image: Image(decorative: frame, scale: 1))) {
                            Image(systemName: "square.and.arrow.up").font(.title3.weight(.semibold))
                                .frame(width: 46, height: 46).background(.black.opacity(0.78), in: Circle())
                        }.foregroundStyle(.white).accessibilityLabel("Share JPEG").accessibilityIdentifier("cover.share")
                            .padding(8)
                    } else if !failed {
                        ProgressView().frame(width: 46, height: 46).background(.black.opacity(0.78), in: Circle())
                            .padding(8).accessibilityLabel("Preparing full-resolution JPEG")
                    }
                }
            if failed {
                VStack(spacing: 8) {
                    Text("Couldn’t load this frame")
                    Button("Try again") { failed = false }.buttonStyle(.bordered)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }.navigationTitle(coverTimestamp(time)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { select(source.pool.randomAlternative(to: pick)) } label: {
                        Label("Update", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                    }.disabled(source.pool.count < 2)
                        .accessibilityHint("Show another random frame from the same range.")
                        .accessibilityIdentifier("cover.detail.update")
                }
            }
            .task(id: renderedPick != pick && !failed) {
                guard renderedPick != pick, !failed else { return }
                let generator = source.generator(thumbnail: false)
                // Keep one decode in flight. A continuing drag can show its
                // result immediately and skip directly to the latest request.
                await withTaskCancellationHandler {
                    while !Task.isCancelled && renderedPick != pick {
                        let target = pick
                        do {
                            let result = try await generator.image(at: TrackRenderer.time(source.pool.time(of: target)))
                            try Task.checkCancellation()
                            frame = result.image
                            renderedPick = target
                        } catch {
                            if Task.isCancelled { return }
                            if pick == target { failed = true; return }
                        }
                    }
                } onCancel: { generator.cancelAllCGImageGeneration() }
            }
            .task(id: sharePick) {
                guard let target = sharePick, jpeg?.pick != target, let frame else { return }
                do {
                    let encoded = try await CoverJPEG.encode(frame, title: source.title, time: source.pool.time(of: target))
                    try Task.checkCancellation()
                    if sharePick == target { jpeg = (target, encoded) }
                } catch { if !Task.isCancelled && sharePick == target { failed = true } }
            }
    }
}
