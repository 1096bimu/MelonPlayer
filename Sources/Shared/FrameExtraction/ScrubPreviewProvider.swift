import Foundation
import CoreGraphics
import AetherEngine

/// Session-scoped scrub-preview source. Configured once per playback session
/// with the session's `FrameExtractor`, then driven by
/// `update(fraction:durationSeconds:)` as the user scrubs. Publishes a
/// ready-to-draw `CGImage` so the transport bar stays free of extraction
/// detail. The extractor (owned by `PlayerViewModel`) handles decode, caching,
/// and cancel-on-supersede internally.
@Observable
@MainActor
final class ScrubPreviewProvider {

    /// The frame to draw above the playhead. Nil means "no image".
    private(set) var previewImage: CGImage?

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var extractor: FrameExtractor?

    // Debounce + staleness control.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

#if os(macOS)
    static let timelineCount = 48
    @ObservationIgnored private var timelineExtractor: FrameExtractor?
    func configureTimeline(extractor: FrameExtractor?, duration: Double) {
        timelineExtractor = extractor
        buildTimeline(duration: duration)
    }
    private(set) var timelineFrames: [Int: CGImage] = [:]
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineDuration = 0.0
    func buildTimeline(duration: Double) {
        guard duration.isFinite, duration > 0, enabled, let extractor = timelineExtractor,
              timelineDuration != duration else { return }
        timelineDuration = duration
        timelineTask?.cancel()
        timelineFrames = [:]
        timelineTask = Task { [weak self] in
            var indices: [Int] = []
            var divisions = 4
            while true {
                for part in 0..<divisions {
                    let index = part * Self.timelineCount / divisions
                    if !indices.contains(index) { indices.append(index) }
                }
                if divisions == Self.timelineCount { break }
                divisions = min(divisions * 2, Self.timelineCount)
            }
            // Session-coupled extractors deliberately return nil during startup
            // or buffering. Leave those slots pending and retry after yielding.
            var pending = indices
            for _ in 0..<60 {
                guard !Task.isCancelled, !pending.isEmpty else { return }
                var missing: [Int] = []
                for index in pending {
                    guard !Task.isCancelled else { return }
                    let time = (Double(index) + 0.5) / Double(Self.timelineCount) * duration
                    let image = await extractor.thumbnail(at: time, maxWidth: 320)
                    guard !Task.isCancelled else { return }
                    if let image { self?.timelineFrames[index] = image }
                    else { missing.append(index) }
                }
                pending = missing
                if !pending.isEmpty { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }
#endif
    init() {}

    /// Set up for a new playback session. `extractor` is the session extractor
    /// (nil if it could not be built); `enabled` mirrors that availability.
    func configure(extractor: FrameExtractor?, enabled: Bool) {
        reset()
        self.extractor = extractor
        self.enabled = enabled
    }

    /// Open the decode context ahead of the first scrub frame to hide
    /// cold-start latency. Safe to call repeatedly.
    func prewarm() {
        guard enabled, let extractor else { return }
        prewarmTask?.cancel()
        prewarmTask = Task { await extractor.prewarm() }
    }

    /// Drive the preview to a scrub position. `fraction` is 0...1 of the
    /// runtime. Debounced 60 ms so a fast swipe doesn't fire a decode per
    /// frame; the `generation` guard drops stale async results.
    func update(fraction: Double, durationSeconds: Double) {
        guard enabled, let extractor, durationSeconds > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * durationSeconds

        generation += 1
        let gen = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return }
            let image = await extractor.thumbnail(at: seconds, maxWidth: 320)
            guard let self else { return }
            if gen == self.generation { self.previewImage = image }
        }
    }

    /// Clear the visible image but keep the extractor (cheap re-show on the
    /// next scrub). Call on commit / cancel / hide.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        previewImage = nil
    }

    /// Full teardown for end of session. Drops the extractor reference;
    /// `PlayerViewModel` owns the extractor's `shutdown()`.
    func reset() {
#if os(macOS)
        timelineTask?.cancel()
        let oldTimelineExtractor = timelineExtractor
        timelineExtractor = nil
        if let oldTimelineExtractor { Task { await oldTimelineExtractor.shutdown() } }
        timelineTask = nil
        timelineDuration = 0
        timelineFrames = [:]
#endif
        loadTask?.cancel()
        loadTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        previewImage = nil
        extractor = nil
        enabled = false
    }
}
