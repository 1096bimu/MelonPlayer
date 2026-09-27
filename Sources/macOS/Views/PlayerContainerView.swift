import SwiftUI
import AppKit
import Combine
import AetherEngine

struct PlayerContainerView: View {
    let model: PlayerViewModel

    @State private var controlsVisible = true
    @State private var lastActivity = Date()
    @State private var trackPanel: PlaybackPanel?
    /// True while the user is dragging the scrubber. Keeps the controls from
    /// auto-hiding mid-drag, which would tear down the slider and drop the
    /// deferred seek.
    @State private var scrubbing = false
    private let hideInterval: TimeInterval = 3
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Bottom layer: mouse-move tracker (needs hit testing to receive mouseMoved).
            MouseActivityView { lastActivity = Date() }

            AetherPlayerSurface(engine: model.engine)

            ClickView(
                controlsVisible: controlsVisible,
                onSingle: {
                    lastActivity = Date()
                    withAnimation { controlsVisible.toggle() }
                },
                onRight: { model.primaryAction(); lastActivity = Date() },
                onDouble: { toggleFullScreen(); bumpActivity() }
            )

            // Subtitle state (incl. the ~10 Hz subtitleTime clock) is observed
            // inside SubtitleOverlay, not here, so this container body does not
            // re-evaluate every tick during undisturbed playback. (issue #2)
            MacSubtitlePresentation(model: model)
                .id(model.loadedURL)

            if controlsVisible {
                VStack {
                    Spacer()
                    TransportBar(
                        model: model,
                        onPanelTapped: { trackPanel = $0 },
                        onPrevious: { ensureFolderThenAdvance(next: false) },
                        onNext: { ensureFolderThenAdvance(next: true) },
                        scrubbing: $scrubbing
                    )
                }
                .transition(.opacity)
                .popover(item: $trackPanel, arrowEdge: .bottom) { panel in
                    TracksPopover(model: model, panel: panel)
                }
            }

            KeyCatcherView(onKey: handleKey)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(tick) { _ in
            if shouldHideControls(now: Date().timeIntervalSinceReferenceDate,
                                  lastActivity: lastActivity.timeIntervalSinceReferenceDate,
                                  interval: hideInterval),
               model.isPlaying, trackPanel == nil, !scrubbing {
                withAnimation { controlsVisible = false }
            }
        }
    }

    private func bumpActivity() {
        lastActivity = Date()
        if !controlsVisible { withAnimation { controlsVisible = true } }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: model.primaryAction(); bumpActivity(); return true     // Space
        case 53:  // Esc: exit fullscreen if in fullscreen, else stop
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                toggleFullScreen()
            } else {
                model.stop()
            }
            return true
        case 124 where event.modifierFlags.contains(.command):          // Cmd+Right = next
            ensureFolderThenAdvance(next: true); bumpActivity(); return true
        case 123 where event.modifierFlags.contains(.command):          // Cmd+Left = previous
            ensureFolderThenAdvance(next: false); bumpActivity(); return true
        case 123: model.seek(by: -10); bumpActivity(); return true      // Left
        case 124: model.seek(by: 10); bumpActivity(); return true       // Right
        case 126: model.adjustVolume(by: 0.05); bumpActivity(); return true  // Up
        case 125: model.adjustVolume(by: -0.05); bumpActivity(); return true // Down
        case 46: model.toggleMute(); bumpActivity(); return true        // M
        case 3:  toggleFullScreen(); return true                        // F
        // J / K, the pair every other player uses for this. No bumpActivity: the on-screen notice states
        // the new value on its own, and raising the transport bar over the picture is the opposite of
        // what someone matching lip movement by ear needs.
        case 38: model.adjustAudioDelay(by: -AudioDelay.step); return true   // J
        case 40: model.adjustAudioDelay(by: AudioDelay.step); return true    // K
        default: return false
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func ensureFolderThenAdvance(next: Bool) {
        if model.playlist != nil {
            Task { if next { await model.playNext() } else { await model.playPrevious() } }
            return
        }
        guard let current = model.loadedURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current.deletingLastPathComponent()
        panel.message = "Grant access to this folder to play the next file."
        if panel.runModal() == .OK, let folder = panel.url {
            let bm = BookmarkAccess.bookmark(for: folder)
            model.adoptFolderPlaylist(folderURL: folder, around: current, bookmarkData: bm)
            Task { if next { await model.playNext() } else { await model.playPrevious() } }
        }
    }
}

/// Clicks toggle chrome; an actual drag moves the window without also clicking.
private struct ClickView: NSViewRepresentable {
    let controlsVisible: Bool
    let onSingle: () -> Void
    let onRight: () -> Void
    let onDouble: () -> Void

    func makeNSView(context: Context) -> ClickSurface { ClickSurface() }
    func updateNSView(_ view: ClickSurface, context: Context) {
        view.onSingle = onSingle
        view.onDouble = onDouble
        view.onRight = onRight
        view.chromeVisible = controlsVisible
        view.updateChrome()
    }
    static func dismantleNSView(_ view: ClickSurface, coordinator: ()) {
        view.restoreChrome()
    }

    final class ClickSurface: NSView {
        var onSingle: (() -> Void)?
        var onRight: (() -> Void)?
        var onDouble: (() -> Void)?
        private var pendingClick: DispatchWorkItem?
        var chromeVisible = true
        private var downEvent: NSEvent?
        private var dragged = false
        private weak var chromeWindow: NSWindow?
        private var originalTransparent = false
        private var originalTitleVisibility: NSWindow.TitleVisibility = .visible
        private var originalFullSize = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restoreChrome()
            guard let window else { return }
            chromeWindow = window
            originalTransparent = window.titlebarAppearsTransparent
            originalTitleVisibility = window.titleVisibility
            originalFullSize = window.styleMask.contains(.fullSizeContentView)
            window.styleMask.insert(.fullSizeContentView)
            window.acceptsMouseMovedEvents = true
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                center.addObserver(self, selector: #selector(updateChrome), name: name, object: window)
            }
            updateChrome()
        }
        @objc func updateChrome() {
            guard let window = chromeWindow else { return }
            let fullScreen = window.styleMask.contains(.fullScreen)
            // One policy for the background, title and traffic lights. Transport
            // visibility remains independent in fullscreen.
            let titleBarVisible = fullScreen || chromeVisible
            window.titlebarAppearsTransparent = !titleBarVisible
            window.titleVisibility = titleBarVisible ? .visible : .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = !titleBarVisible
            }
            NSCursor.setHiddenUntilMouseMoves(window.isKeyWindow &&
                shouldHideCursor(controlsVisible: chromeVisible, isFullScreen: fullScreen))
        }
        func restoreChrome() {
            NotificationCenter.default.removeObserver(self)
            pendingClick?.cancel()
            pendingClick = nil
            NSCursor.setHiddenUntilMouseMoves(false)
            guard let window = chromeWindow else { return }
            window.titlebarAppearsTransparent = originalTransparent
            window.titleVisibility = originalTitleVisibility
            if !originalFullSize { window.styleMask.remove(.fullSizeContentView) }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = false
            }
            chromeWindow = nil
        }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            downEvent = event
            dragged = false
        }
        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let downEvent else { return }
            let start = downEvent.locationInWindow
            let end = event.locationInWindow
            guard hypot(end.x - start.x, end.y - start.y) >= 3 else { return }
            pendingClick?.cancel()
            pendingClick = nil
            dragged = true
            window?.performDrag(with: downEvent)
        }
        override func mouseUp(with event: NSEvent) {
            if downEvent != nil && !dragged {
                if event.clickCount == 2 {
                    pendingClick?.cancel()
                    pendingClick = nil
                    onDouble?()
                } else {
                    pendingClick?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.onSingle?() }
                    pendingClick = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
                }
            }
            downEvent = nil
        }
        override func rightMouseUp(with event: NSEvent) { onRight?() }
        override func rightMouseDown(with event: NSEvent) {}
    }
}

/// Tracks mouse movement over the player and reports activity.
private struct MouseActivityView: NSViewRepresentable {
    let onMove: () -> Void
    func makeNSView(context: Context) -> _Tracking {
        let v = _Tracking(); v.onMove = onMove; return v
    }
    func updateNSView(_ nsView: _Tracking, context: Context) { nsView.onMove = onMove }

    final class _Tracking: NSView {
        var onMove: (() -> Void)?
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: bounds,
                                   options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a); area = a
        }
        override func mouseMoved(with event: NSEvent) { onMove?() }
    }
}

// Internal ASS uses direct libass; Plain is a separate adjustable SwiftUI layer.
private struct MacSubtitlePresentation: View {
    let model: PlayerViewModel
    var body: some View {
        GeometryReader { geometry in
            if model.subtitleRole == .plain {
                let text = plainText
                if !text.isEmpty {
                    AdjustableSubtitleOrnament(text: text, paused: !model.isPlaying, videoSize: geometry.size)
                }
            } else if model.subtitleRole == .internal {
                if let header = model.macASSHeader {
                    MacASSOverlay(model: model, header: header).allowsHitTesting(false)
                } else {
                    SubtitleOverlay(model: model).allowsHitTesting(false)
                }
            }
        }
    }
    private var plainText: String {
        model.subtitleCues.filter { $0.startTime <= model.subtitleTime && model.subtitleTime < $0.endTime }
            .compactMap { cue -> String? in
                switch cue.body {
                case .text(let text):
                    return ["ass", "ssa"].contains(model.activeSubtitleCodec ?? "") ? AetherSubtitleText.plain(text) : text
                case .richText(let runs): return runs.map(\.text).joined()
                case .image: return nil
                }
            }.joined(separator: "\n")
    }
}

private struct MacASSOverlay: NSViewRepresentable {
    let model: PlayerViewModel
    let header: String
    func makeNSView(context: Context) -> MacASSCanvas { MacASSCanvas() }
    func updateNSView(_ view: MacASSCanvas, context: Context) {
        view.configure(header: header, trackID: model.selectedSubtitleIndex ?? -1,
            fonts: model.engine.fontAttachments.map { ASSFont(filename: $0.filename, data: $0.data) },
            cues: model.subtitleCues.compactMap {
                guard case .text(let text) = $0.body else { return nil }
                return ASSEvent(startTime: $0.startTime, endTime: $0.endTime, text: text)
            }, time: model.subtitleTime, playing: model.isPlaying, rate: Double(model.rate))
    }
    static func dismantleNSView(_ view: MacASSCanvas, coordinator: ()) { view.close() }
}

@MainActor private final class MacASSCanvas: NSView {
    private let worker = ASSFrameWorker()
    private var animationLink: CADisplayLink?
    private var active = true
    private var busy = false
    private var revision = 0
    private var time = 0.0
    private var hostTime = 0.0
    private var playing = false
    private var rate = 1.0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(header: String, trackID: Int, fonts: [ASSFont], cues: [ASSEvent], time: Double, playing: Bool, rate: Double) {
        revision += 1
        self.time = time; self.hostTime = CACurrentMediaTime()
        self.playing = playing; self.rate = rate
        worker.update(header: header, trackID: trackID, fonts: fonts, cues: cues)
        if animationLink == nil {
            let link = displayLink(target: self, selector: #selector(displayTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            animationLink = link
        }
        animationLink?.isPaused = !playing
        render()
    }
    override func layout() { super.layout(); revision += 1; render() }
    @objc private func displayTick() { render() }
    private func render() {
        guard active, !busy, bounds.width > 0, bounds.height > 0 else { return }
        busy = true
        let requestedRevision = revision
        let scale = min(window?.backingScaleFactor ?? 2, 2560 / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let now = time + (playing ? min(0.2, CACurrentMediaTime() - hostTime) * rate : 0)
        worker.render(time: now, size: size) { [weak self] image, changed in
            guard let self else { return }
            self.busy = false
            guard self.active else { return }
            if self.revision != requestedRevision {
                // A paused seek/resize may arrive while the worker is busy.
                // Render the latest request even when no animation timer runs.
                self.render()
            }
            guard changed else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.layer?.contents = image
            CATransaction.commit()
        }
    }
    func close() {
        active = false
        animationLink?.invalidate(); animationLink = nil
        layer?.contents = nil
        worker.reset()
    }
}

import Foundation
import CoreGraphics
import libass

nonisolated struct ASSFont: Sendable {
    let filename: String
    let data: Data
}
nonisolated struct ASSEvent: Sendable {
    let startTime: Double
    let endTime: Double
    let text: String
}

/// All libass access and bitmap composition runs on one worker, never on the UI
/// thread. Only changed frames are copied; static captions reuse their texture.
nonisolated final class ASSFrameWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "melon.aether.ass", qos: .userInitiated)
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var identity = ""
    private var seen = Set<String>()
    private var size = CGSize.zero
    private var dirty = true

    func update(header: String, trackID: Int, fonts: [ASSFont], cues: [ASSEvent]) {
        queue.async { [self] in
            let key = "\(trackID)|\(fonts.count)|\(header)"
            if key != identity {
                destroy()
                identity = key
                library = ass_library_init()
                guard let library else { return }
                for font in fonts {
                    guard font.data.count <= Int(Int32.max) else { continue }
                    font.data.withUnsafeBytes { bytes in
                        guard let raw = bytes.baseAddress else { return }
                        ass_add_font(library, font.filename, raw.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
                    }
                }
                renderer = ass_renderer_init(library)
                guard let renderer else { return }
                ass_set_fonts(renderer, nil, "Arial", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
                track = ass_new_track(library)
                guard let track else { return }
                header.withCString { ass_process_codec_private(track, $0, Int32(strlen($0))) }
                // Some real MKVs reuse ReadOrder=0. Deduplicate by cue content
                // ourselves, so libass must not discard their subsequent lines.
                ass_set_check_readorder(track, 0)
            }
            guard let track else { return }
            for cue in cues {
                guard cue.startTime.isFinite, cue.endTime.isFinite else { continue }
                let text = cue.text
                for raw in text.split(separator: "\n") {
                    let key = "\(cue.startTime)|\(cue.endTime)|\(raw)"
                    guard seen.insert(key).inserted else { continue }
                    String(raw).withCString {
                        ass_process_chunk(track, $0, Int32(strlen($0)), Int64(cue.startTime * 1000),
                                          Int64(max(0, cue.endTime - cue.startTime) * 1000))
                    }
                    dirty = true
                }
            }
        }
    }
    func render(time: Double, size: CGSize, completion: @escaping @MainActor @Sendable (CGImage?, Bool) -> Void) {
        queue.async { [self] in
            guard let renderer, let track, time.isFinite, size.width > 0, size.height > 0 else {
                Task { @MainActor in completion(nil, true) }; return
            }
            if self.size != size {
                self.size = size; dirty = true
                ass_set_frame_size(renderer, Int32(size.width), Int32(size.height))
            }
            var changed: Int32 = 0
            let images = ass_render_frame(renderer, track, Int64(time * 1000), &changed)
            let update = dirty || changed != 0
            dirty = false
            let image = update ? Self.compose(images, width: Int(size.width), height: Int(size.height)) : nil
            Task { @MainActor in completion(image, update) }
        }
    }
    static func compose(_ first: UnsafeMutablePointer<ASS_Image>?, width: Int, height: Int) -> CGImage? {
        guard first != nil, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var next = first
        while let node = next {
            let image = node.pointee; next = image.next
            let w = Int(image.w), h = Int(image.h)
            guard w > 0, h > 0, let bitmap = image.bitmap else { continue }
            // libass already supplies coverage. Let Core Graphics apply the
            // constant color/opacity instead of expanding every pixel in Swift.
            let count = (h - 1) * Int(image.stride) + w
            let coverage = Data(bytes: bitmap, count: count)
            guard let provider = CGDataProvider(data: coverage as CFData) else { continue }
            // CG image masks use inverse coverage: decode reverses that so
            // libass 0 remains transparent and 255 remains fully covered.
            var decode: [CGFloat] = [1, 0]
            let mask = decode.withUnsafeMutableBufferPointer {
                CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: Int(image.stride), provider: provider,
                        decode: $0.baseAddress, shouldInterpolate: false)
            }
            guard let mask else { continue }
            let rect = CGRect(x: Int(image.dst_x), y: height - Int(image.dst_y) - h, width: w, height: h)
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(red: CGFloat((image.color >> 24) & 255) / 255,
                                 green: CGFloat((image.color >> 16) & 255) / 255,
                                 blue: CGFloat((image.color >> 8) & 255) / 255,
                                 alpha: CGFloat(255 - (image.color & 255)) / 255)
            context.fill(rect)
            context.restoreGState()
        }
        return context.makeImage()
    }
    func reset() { queue.async { [self] in destroy() } }
    private func destroy() {
        if let track { ass_free_track(track) }
        if let renderer { ass_renderer_done(renderer) }
        if let library { ass_library_done(library) }
        track = nil; renderer = nil; library = nil; identity = ""; seen.removeAll(); size = .zero; dirty = true
    }
    deinit { destroy() }
}

import Foundation

/// Plain mode intentionally removes ASS styling, event fields and vector drawings.
nonisolated enum AetherSubtitleText {
    static func plain(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let body = parts.count == 9 && Int(parts[0]) != nil ? String(parts[8]) : String(line)
            var remaining = body[...]
            var drawing = false
            var text = ""
            while let tag = remaining.range(of: #"\{[^}]*\}"#, options: .regularExpression) {
                if !drawing { text += remaining[..<tag.lowerBound] }
                let command = String(remaining[tag])
                if let p = command.range(of: #"\\p\d+"#, options: .regularExpression) {
                    drawing = Int(command[p].dropFirst(2)) != 0
                }
                remaining = remaining[tag.upperBound...]
            }
            if !drawing { text += remaining }
            text = text.replacingOccurrences(of: #"\N"#, with: "\n")
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\h"#, with: "\u{00a0}")
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }
}

import SwiftUI

struct AdjustableSubtitleOrnament: View {
    let text: String
    let paused: Bool
    let videoSize: CGSize
    @AppStorage("subtitleOrnament.offsetX") private var offsetX = 0.0
    @AppStorage("subtitleOrnament.offsetY") private var offsetY = 0.0
    @AppStorage("subtitleOrnament.scale") private var scale = 1.0
    @GestureState private var translation = CGSize.zero
    @GestureState private var magnification = 1.0

    private var subtitleScale: Double { min(3, max(0.5, scale * magnification)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.allowsHitTesting(false)
            subtitle
                .frame(maxWidth: videoSize.width * 0.85)
                .padding(.bottom, videoSize.height * 0.08)
        }
        .frame(width: videoSize.width, height: videoSize.height)
        .clipped()
    }

    private var subtitle: some View {
        Text(verbatim: text)
            .font(.system(size: min(30, max(18, videoSize.width * 0.03)) * subtitleScale, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16 * subtitleScale)
            .padding(.vertical, 8 * subtitleScale)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10 * subtitleScale))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                offsetX = 0
                offsetY = 0
                scale = 1
            }
            .gesture(DragGesture(coordinateSpace: .global)
                .updating($translation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    guard paused else { return }
                    offsetX = min(0.45, max(-0.45, offsetX + value.translation.width / max(1, videoSize.width)))
                    offsetY = min(0.05, max(-0.85, offsetY + value.translation.height / max(1, videoSize.height)))
                })
            .simultaneousGesture(MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    guard paused else { return }
                    scale = min(3, max(0.5, scale * value.magnification))
                })
            .offset(x: offsetX * videoSize.width + translation.width,
                    y: offsetY * videoSize.height + translation.height)
            .allowsHitTesting(paused)
            .accessibilityHint(paused ? "Drag to move, pinch to resize, or double tap to reset." : "")
    }
}
