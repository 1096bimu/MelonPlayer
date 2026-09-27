import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AetherEngine

struct ContentView: View {
    @State private var model: PlayerViewModel
    @State private var isDropTargeted = false
    let onOpenURL: () -> Void

    init(model: PlayerViewModel, onOpenURL: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onOpenURL = onOpenURL
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.hasMedia {
                if model.isAudioOnly {
                    NowPlayingView(model: model)
                        .ignoresSafeArea()
                } else {
                    PlayerContainerView(model: model)
                        .ignoresSafeArea()
                }
            } else {
                EmptyStateView(
                    isDropTargeted: isDropTargeted,
                    onOpen: openPanel,
                    onOpenURL: onOpenURL,
                    recents: model.recents.items,
                    thumbnails: model.recentsThumbnails,
                    onOpenRecent: { item in Task { await model.openRecent(item) } },
                    onRemoveRecent: { model.recents.remove($0) },
                    onClearRecents: { model.recents.clearAll() }
                )
            }

            if model.state == .loading && !model.hasMedia {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Opening stream\u{2026}")
                        Button("Cancel") { model.cancelLoading() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let err = model.loadError {
                VStack {
                    Spacer()
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }

            // Top-centre rather than at the bottom with the other two toasts: the audio-drop notice and
            // the resume toast both arrive right after a load, and the delay notice would otherwise sit
            // under the transport bar, which is up while someone is nudging by ear.
            if let notice = model.notice {
                VStack {
                    HStack(spacing: 8) {
                        if notice.kind == .warning {
                            Image(systemName: "speaker.slash.fill")
                        }
                        Text(notice.text)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(notice.seconds))
                    model.dismissNotice(id: notice.id)
                }
            }

            if let msg = model.resumeMessage {
                VStack {
                    Spacer()
                    ResumeToastView(message: msg, onStartOver: { model.startOver() })
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(6))
                    model.dismissResumeMessage()
                }
            }
        }
        .background(PlayerWindowBinding(model: model))
        .background(PlaybackBrightnessWindowBinding(active: model.hasMedia))
        .animation(.easeInOut(duration: 0.25), value: model.loadError)
        .animation(.easeInOut(duration: 0.25), value: model.resumeMessage)
        .animation(.easeInOut(duration: 0.2), value: model.notice)
        .animation(.easeInOut(duration: 0.2), value: model.state == .loading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        let bm = BookmarkAccess.bookmark(for: url)
                        await model.openFolder(url, bookmarkData: bm)
                    } else if Self.subtitleExtensions.contains(url.pathExtension.lowercased()), model.hasMedia {
                        // A subtitle file dropped onto a playing video attaches as
                        // a sidecar track; anything else loads as a new video.
                        model.loadSidecarSubtitle(url: url)
                    } else {
                        await model.open(url: url)
                    }
                }
            }
            return true
        }
        .onChange(of: model.loadedURL) { _, _ in updateWindowTitle() }
        .onChange(of: model.metadata) { _, _ in updateWindowTitle() }
        .onChange(of: model.isAudioOnly) { _, _ in updateWindowTitle() }
        .onChange(of: model.loadError) { _, err in
            // Auto-dismiss the error toast after a few seconds, unless a newer
            // error replaced it in the meantime.
            guard err != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if model.loadError == err { model.clearLoadError() }
            }
        }
    }

    /// Sidecar subtitle file extensions recognized on drop.
    private static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]

    private func updateWindowTitle() {
        NSApp.keyWindow?.title = windowTitle(
            metadata: model.metadata, url: model.loadedURL, isAudio: model.isAudioOnly)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .audio, .discImage]
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.open(url: url) }
        }
    }
}

/// Binds only the owning playback window; closing Settings or a popover must
/// never stop playback. AppKit constraints leave fullscreen to the system.
private struct PlayerWindowBinding: NSViewRepresentable {
    let model: PlayerViewModel
    func makeNSView(context: Context) -> PlayerWindowObserver {
        let view = PlayerWindowObserver()
        view.model = model
        return view
    }
    func updateNSView(_ view: PlayerWindowObserver, context: Context) { view.model = model }
    static func dismantleNSView(_ view: PlayerWindowObserver, coordinator: ()) { view.detach() }
}

private final class PlayerWindowObserver: NSView {
    weak var model: PlayerViewModel?
    private var timer: Timer?
    private weak var attachedWindow: NSWindow?
    private var lastAspect: CGFloat?
    private var closing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        attachedWindow = window
        closing = false
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(leftFullscreen), name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowActivated), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowActivated), name: NSWindow.didBecomeMainNotification, object: window)
        startAspectUpdates()
        // Attaching a hosting view can itself be inside an AppKit layout pass.
        DispatchQueue.main.async { [weak self] in self?.updateAspect() }
    }
    func detach() {
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        attachedWindow = nil
        lastAspect = nil
    }
    @objc private func windowClosing() {
        // A SwiftUI Window may be reused without viewDidMoveToWindow firing.
        // Every actual close must stop the session, even after a previous close.
        closing = true
        timer?.invalidate(); timer = nil
        attachedWindow?.contentResizeIncrements = NSSize(width: 1, height: 1)
        lastAspect = nil
        // Do not replace the hosting view tree inside NSWindow's close callback.
        let model = model
        DispatchQueue.main.async { model?.stop() }
    }
    @objc private func windowActivated() {
        guard attachedWindow != nil else { return }
        if closing {
            closing = false
            lastAspect = nil
        }
        startAspectUpdates()
        // Keep size changes outside AppKit's window activation/layout callback.
        DispatchQueue.main.async { [weak self] in self?.updateAspect() }
    }

    private func startAspectUpdates() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAspect() }
        }
    }

    @objc private func leftFullscreen() { lastAspect = nil; updateAspect() }

    private func updateAspect() {
        guard !closing, let window = attachedWindow, window.isVisible, let model else { return }
        guard model.hasMedia, !model.isAudioOnly else {
            if lastAspect != nil { window.contentResizeIncrements = NSSize(width: 1, height: 1); lastAspect = nil }
            return
        }
        let engine = model.engine
        let size = engine.softwareDisplaySize ?? engine.currentAVPlayer?.currentItem?.presentationSize
            ?? CGSize(width: Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio, height: Double(engine.sourceVideoHeight))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let ratio = size.width / size.height
        guard lastAspect == nil || abs(ratio - lastAspect!) > 0.0001 else { return }
        lastAspect = ratio
        window.contentAspectRatio = NSSize(width: ratio, height: 1)
        guard !window.styleMask.contains(.fullScreen) else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        var width = max(content.width, max(640, 360 * ratio))
        if let screen = window.screen {
            let available = window.contentRect(forFrameRect: screen.visibleFrame).size
            width = min(width, min(available.width, available.height * ratio))
        }
        content.size = NSSize(width: width, height: width / ratio)
        var frame = window.frameRect(forContentRect: content)
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }
}
