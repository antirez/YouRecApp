import SwiftUI
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import ImageIO

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
        rangeLabel = editorTime(scope.map(\.start).min()?.seconds ?? 0) + " – " + editorTime(scope.map(\.end).max()?.seconds ?? 0)
        var picture = timeline.video.map(\.interval)
        // A Still transition can extend the outgoing picture beyond its clip.
        for join in timeline.transitions where join.settings.style == .still && join.outgoing != nil {
            let timing = TransitionTiming(join.settings, factor: join.factor, edge: join.incoming == nil ? 1 : 0)
            picture.append(EditInterval(join.origin, min(timeline.duration, join.origin + EditTime(timing.videoDuration))))
        }
        pool = CoverFramePool(picture: picture, scope: scope)
    }

    func generator(thumbnail: Bool) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = composition
        if thumbnail { generator.maximumSize = CGSize(width: 512, height: 512) }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if #available(iOS 18.0, *) { generator.dynamicRangePolicy = .forceSDR }
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
        let timestamp = editorTime(time.seconds).replacingOccurrences(of: ":", with: "-")
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
                            let stamp = editorTime(source.pool.time(of: pick).seconds)
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
                CoverDetail(source: source, time: source.pool.time(of: pick), thumbnail: thumbnails[pick])
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
    let time: EditTime
    let thumbnail: CGImage?
    @State private var frame: CGImage?
    @State private var jpeg: CoverJPEG?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color(white: 0.07).aspectRatio(source.aspect, contentMode: .fit)
                .overlay {
                    if let picture = frame ?? thumbnail {
                        Image(picture, scale: 1, label: Text("Cover image")).resizable().scaledToFit()
                            .accessibilityValue("\(picture.width) × \(picture.height) pixels")
                            .accessibilityIdentifier("cover.image")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let jpeg, let frame {
                        ShareLink(item: jpeg, preview: SharePreview(jpeg.filename, image: Image(decorative: frame, scale: 1))) {
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
                    Button("Try again") { failed = false; attempt += 1 }.buttonStyle(.bordered)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }.navigationTitle(editorTime(time.seconds)).navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                guard jpeg == nil else { return }
                let generator = source.generator(thumbnail: false)
                do {
                    let result = try await withTaskCancellationHandler {
                        try await generator.image(at: TrackRenderer.time(time))
                    } onCancel: { generator.cancelAllCGImageGeneration() }
                    try Task.checkCancellation()
                    frame = result.image
                    let encoded = try await CoverJPEG.encode(result.image, title: source.title, time: time)
                    try Task.checkCancellation()
                    jpeg = encoded
                } catch { if !Task.isCancelled { failed = true } }
            }
    }
}
