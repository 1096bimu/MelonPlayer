import SwiftUI
import AetherEngine

struct TransportBar: View {
    let model: PlayerViewModel
    let onPanelTapped: (PlaybackPanel) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    @Binding var scrubbing: Bool
    @State private var scrubFraction = 0.0
    @State private var resumeAfterScrub = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.primaryAction() } label: {
                Image(systemName: model.isEnded ? "arrow.counterclockwise" : model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .help("Play / Pause")
            HStack(spacing: 4) {
                Button { model.toggleMute() } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.fill")
                }
                Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), in: 0...1)
                    .frame(width: 64).tint(.white)
            }
            MacPreviewTimeline(model: model, scrubbing: $scrubbing, scrubFraction: $scrubFraction,
                onBegin: {
                    resumeAfterScrub = model.isPlaying
                    if resumeAfterScrub { model.engine.pause() }
                }, onEnd: {
                    if resumeAfterScrub { model.engine.play() }
                    resumeAfterScrub = false
                })
            VStack(spacing: 3) {
                Text(formatTimecode(scrubbing ? scrubFraction * model.duration : model.currentTime))
                Divider().overlay(.white.opacity(0.25))
                Text(formatTimecode(model.duration)).foregroundStyle(.secondary)
            }
            .font(.system(.caption, design: .monospaced)).frame(width: 66)
            BalancedControlButtons {
                if model.backend != .audio {
                    Button { SnapshotSaver.captureAndSave(model: model) } label: { Image(systemName: "camera") }
                        .disabled(!model.hasMedia).help("Save screenshot")
                }
                if model.audioTracks.count > 1 {
                    Button { onPanelTapped(.audio) } label: { Image(systemName: "waveform.mid") }.help("Audio")
                }
                if !model.subtitleTracks.isEmpty {
                    Button { onPanelTapped(.subtitles) } label: { Image(systemName: "captions.bubble") }.help("Subtitles")
                }
                if !model.playbackChapters.isEmpty || !model.discTitles.isEmpty {
                    Button { onPanelTapped(.chapters) } label: { Image(systemName: "list.and.film") }.help("Chapters")
                }
                Button { PlaybackDisplayBrightness.shared.toggle() } label: {
                    Image(systemName: PlaybackDisplayBrightness.shared.isBoosted ? "sun.max.fill" : "sun.max")
                        .foregroundStyle(PlaybackDisplayBrightness.shared.isBoosted ? Color.yellow : Color.white)
                }
                .disabled(!PlaybackDisplayBrightness.shared.isSupported)
                .help(PlaybackDisplayBrightness.shared.isBoosted ? "Restore display brightness" : "Maximum display brightness")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .padding(12)
        .modifier(PlaybackControlGlass())
        .padding(12)
        .onAppear { model.scrubPreview.buildTimeline(duration: model.duration) }
        .onChange(of: model.duration) { _, duration in model.scrubPreview.buildTimeline(duration: duration) }
        .onDisappear {
            if scrubbing { scrubbing = false; if resumeAfterScrub { model.engine.play() }; resumeAfterScrub = false }
        }
    }
}

/// Fixed midpoint samples fill progressively without moving neighboring slices.
/// Hover and scrub use the same preview, outside the strip's clipping mask.
private struct MacPreviewTimeline: View {
    let model: PlayerViewModel
    @Binding var scrubbing: Bool
    @Binding var scrubFraction: Double
    let onBegin: () -> Void
    let onEnd: () -> Void
    @State private var hoverFraction: Double?
    private let height: CGFloat = 44
    private var count: Int { ScrubPreviewProvider.timelineCount }
    private func index(_ fraction: Double) -> Int { min(count - 1, max(0, Int(fraction * Double(count)))) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let cell = width / CGFloat(count)
            let inset = min(1, cell / 4)
            let active = min(1, max(0, scrubbing ? scrubFraction : (model.duration > 0 ? model.currentTime / model.duration : 0)))
            let target = scrubbing ? scrubFraction : hoverFraction
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.8))
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { slot in
                        ZStack {
                            if let image = model.scrubPreview.timelineFrames[slot] {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                                    .frame(width: max(0, cell - inset * 2), height: height - 4)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }.frame(width: cell, height: height)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 7))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.35), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1).fill(.white)
                    .frame(width: 3, height: height + 4)
                    .offset(x: min(width - 3, max(0, active * width - 1.5)))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard model.duration > 0 else { return }
                    if !scrubbing { onBegin(); scrubbing = true }
                    scrubFraction = fraction(forX: value.location.x, width: width)
                    model.scrubPreview.update(fraction: scrubFraction, durationSeconds: model.duration)
                }
                .onEnded { value in
                    guard scrubbing else { return }
                    let fraction = fraction(forX: value.location.x, width: width)
                    scrubFraction = fraction
                    model.seek(to: fraction * model.duration)
                    scrubbing = false
                    onEnd()
                    if hoverFraction == nil { model.scrubPreview.clear() }
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverFraction = fraction(forX: point.x, width: width)
                    if !scrubbing, let hoverFraction {
                        model.scrubPreview.update(fraction: hoverFraction, durationSeconds: model.duration)
                    }
                case .ended:
                    hoverFraction = nil
                    if !scrubbing { model.scrubPreview.clear() }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let target, let image = model.scrubPreview.previewImage ?? model.scrubPreview.timelineFrames[index(target)] {
                    ScrubThumbnail(image: image, time: target * model.duration)
                        .offset(x: scrubThumbX(fraction: target, width: width, thumbWidth: 160), y: -height - 10)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Playback position")
            .accessibilityValue(formatTimecode(model.currentTime))
            .accessibilityAdjustableAction { model.seek(by: $0 == .increment ? 10 : -10) }
        }
        .frame(minWidth: 100, maxWidth: .infinity).frame(height: height)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

/// Retains the original floating seek preview above the timeline.
private struct ScrubThumbnail: View {
    let image: CGImage
    let time: Double
    private let width: CGFloat = 160
    private var height: CGFloat { width * CGFloat(image.height) / CGFloat(max(1, image.width)) }
    var body: some View {
        VStack(spacing: 2) {
            Image(decorative: image, scale: 1).resizable()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6), lineWidth: 1))
            Text(formatTimecode(time))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.6), in: Capsule())
        }
        .fixedSize()
        .shadow(radius: 6)
    }
}

/// Row-major order, with the extra item on the first row for odd counts.
struct BalancedControlButtons: Layout {
    private let cell: CGFloat = 24
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let columns = subviews.count >= 3 ? (subviews.count + 1) / 2 : subviews.count
        return CGSize(width: CGFloat(columns) * cell, height: subviews.count >= 3 ? 48 : 24)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = subviews.count >= 3 ? (subviews.count + 1) / 2 : max(1, subviews.count)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * cell + cell / 2,
                                   y: bounds.minY + CGFloat(index / columns) * cell + cell / 2),
                       anchor: .center, proposal: ProposedViewSize(width: cell, height: cell))
        }
    }
}

import AppKit
import Darwin

/// App-owned adapter; leaves AetherEngine untouched. Unsupported displays are inert.
@MainActor @Observable final class PlaybackDisplayBrightness {
    static let shared = PlaybackDisplayBrightness()
    private(set) var isBoosted = false
    private(set) var isSupported = false
    private var displayID: CGDirectDisplayID?
    private var saved: [CGDirectDisplayID: Float] = [:]
    private let api = PlaybackBrightnessAPI()

    func select(screen: NSScreen?, active: Bool) {
        let id = active ? (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value : nil
        if id != displayID {
            restore()
            displayID = id
            isBoosted = false
        }
        isSupported = id.flatMap { api.read($0) } != nil
    }
    func toggle() {
        guard let id = displayID else { return }
        if isBoosted { restore(); return }
        guard saved.isEmpty, let previous = api.read(id), previous < 1 else { return }
        if api.write(1, to: id) {
            saved[id] = previous
            isBoosted = true
        }
    }
    func restore() {
        for (id, value) in saved {
            if api.write(value, to: id) { saved.removeValue(forKey: id) }
        }
        isBoosted = displayID.map { saved[$0] != nil } ?? false
    }
}

private final class PlaybackBrightnessAPI {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private let canChange: CanChange?
    private let get: Get?
    private let set: Set?
    // Keep the handle loaded for the lifetime of the function pointers.
    private let handle: UnsafeMutableRawPointer?
    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        self.handle = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        canChange = symbol("DisplayServicesCanChangeBrightness", CanChange.self)
        get = symbol("DisplayServicesGetBrightness", Get.self)
        set = symbol("DisplayServicesSetBrightness", Set.self)
    }
    func read(_ id: CGDirectDisplayID) -> Float? {
        guard canChange?(id) == true, let get, set != nil else { return nil }
        var value: Float = -1
        guard get(id, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    func write(_ value: Float, to id: CGDirectDisplayID) -> Bool {
        guard read(id) != nil else { return false }
        return set?(id, value) == 0
    }
}

/// Mounted outside the auto-hiding controls so their disappearance never resets the boost.
struct PlaybackBrightnessWindowBinding: NSViewRepresentable {
    let active: Bool
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.active = active; view.refresh() }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.detach() }
    final class Observer: NSView {
        var active = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { detach(); return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(refresh), name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(self, selector: #selector(stop), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(stop), name: NSApplication.willTerminateNotification, object: nil)
            center.addObserver(self, selector: #selector(refresh), name: NSApplication.didChangeScreenParametersNotification, object: nil)
            refresh()
        }
        @objc func refresh() { PlaybackDisplayBrightness.shared.select(screen: window?.screen, active: active) }
        @objc func stop() { PlaybackDisplayBrightness.shared.select(screen: nil, active: false) }
        func detach() { NotificationCenter.default.removeObserver(self); stop() }
    }
}

private struct PlaybackControlGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
