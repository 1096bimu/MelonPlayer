import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AetherEngine

enum PlaybackPanel: String, Identifiable {
    case audio, subtitles, chapters
    var id: String { rawValue }
}

struct TracksPopover: View {
    let model: PlayerViewModel
    var panel: PlaybackPanel = .subtitles

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch panel {
                    case .audio:
                        Text("Audio").font(.headline)
                        ForEach(model.melonAudioTracks) { track in
                            Button { model.selectAudio(engineIndex: track.id) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(track.label)
                                        Text(track.details).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.activeAudioTrackIndex == track.id { Image(systemName: "checkmark") }
                                }
                            }.buttonStyle(.plain)
                        }
                    case .subtitles:
                        Text("Subtitles").font(.headline)
                        ForEach(model.melonSubtitleTracks) { track in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(track.label)
                                if track.languageKey != nil {
                                    Text(track.language).font(.caption).foregroundStyle(.secondary)
                                }
                                Picker(track.label, selection: Binding(
                                    get: { model.subtitleMode(for: track.id) },
                                    set: { model.setSubtitleMode($0, for: track.id) })) {
                                    ForEach(SubtitleMode.allCases, id: \.self) { mode in
                                        if mode != .plain || model.canUsePlain(track.id) {
                                            Text(mode.localizedLabel).tag(mode)
                                        }
                                    }
                                }.pickerStyle(.segmented).labelsHidden()
                            }
                        }
                        Button("Load Subtitle File…", action: loadSidecar)
                    case .chapters:
                        Text("Chapters").font(.headline)
                        ForEach(model.playbackChapters) { chapter in
                            Button { model.selectPlaybackChapter(chapter) } label: {
                                HStack {
                                    if chapter.id == model.currentChapterID { Image(systemName: "play.fill") }
                                    Text(chapter.name.isEmpty ? "Chapter \(chapter.id + 1)" : chapter.name)
                                    Spacer()
                                    Text(formatTimecode(chapter.startSeconds)).monospacedDigit().foregroundStyle(.secondary)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(chapter.id == model.currentChapterID ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                            }.buttonStyle(.plain).id(chapter.id)
                        }
                        if !model.discTitles.isEmpty {
                            Divider()
                            Text("Titles").font(.headline)
                            ForEach(titleMenuRows(model.discTitles, selectedID: model.selectedDiscTitleID)) { row in
                                Button((row.isSelected ? "✓ " : "") + row.label) { model.selectTitle(id: row.id) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(16)
            }
            .onAppear {
                if panel == .chapters, let id = model.currentChapterID { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(width: 360)
        .frame(maxHeight: tracksPopoverMaxHeight(screenHeight: NSScreen.main?.visibleFrame.height ?? 800))
    }

    private func loadSidecar() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText,
                                     UTType(filenameExtension: "ass") ?? .plainText,
                                     UTType(filenameExtension: "vtt") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { model.loadSidecarSubtitle(url: url) }
    }
}

// App-owned preference models shared with melon video; no engine modifications.


nonisolated enum SubtitleMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case `internal` = "Internal"
    case plain = "Plain"

    var localizedLabel: String {
        switch self {
        case .off: String(localized: "Off")
        case .internal: String(localized: "Internal")
        case .plain: String(localized: "Plain")
        }
    }
}

nonisolated struct SubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let language: String
    let codec: String
    var isDefault = false
    var isForced = false

    var isImageBased: Bool {
        ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub", "pgssub", "dvdsub", "dvbsub"].contains(codec.lowercased())
    }
    var label: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Subtitle \(id)") : name
    }
    var languageKey: String? { SubtitleLanguage.key(language) }
}

nonisolated enum SubtitleLanguage {
    static func key(_ language: String) -> String? {
        let parts = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first, !["und", "unknown", "zxx", "mul"].contains(first) else { return nil }
        // Matroska commonly uses the older bibliographic ISO 639-2 aliases.
        let aliases = ["chi": "zho", "fre": "fra", "ger": "deu", "dut": "nld", "cze": "ces",
                       "gre": "ell", "rum": "ron", "slo": "slk", "wel": "cym", "alb": "sqi",
                       "arm": "hye", "baq": "eus", "bur": "mya", "geo": "kat", "ice": "isl",
                       "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "tib": "bod"]
        let base = aliases[first] ?? first
        let canonical = Locale.LanguageCode(base).identifier(.alpha2) ?? base
        // Preserve explicit script/region distinctions (e.g. zh-Hans vs zh-Hant).
        return ([canonical] + parts.dropFirst()).joined(separator: "-")
    }
}

nonisolated struct SubtitlePreference: Codable, Equatable, Sendable {
    let mode: SubtitleMode
    let order: Int
    var language: String? = nil
    var label: String? = nil
}

/// Only explicit user actions write this store. Auto-selection and capacity
/// limits must never overwrite a language's saved preference.
nonisolated final class SubtitlePreferences {
    private let defaults: UserDefaults
    private let storageKey = "subtitleLanguageModes.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func labelKey(_ label: String) -> String {
        label.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func load() -> [String: SubtitlePreference] {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode([String: SubtitlePreference].self, from: data)
        else { return [:] }
        return preferences
    }

    func save(_ mode: SubtitleMode, language: String, label: String = "") {
        guard let key = SubtitleLanguage.key(language) else { return }
        var preferences = load()
        let order = (preferences.values.map(\.order).max() ?? 0) + 1
        let normalized = Self.labelKey(label)
        // Replace the old language-only entry once a named track is chosen.
        preferences.removeValue(forKey: key)
        preferences[key + "|" + normalized] = SubtitlePreference(mode: mode, order: order, language: key, label: normalized)
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: storageKey) }
    }
}

nonisolated struct SubtitleState: Equatable, Sendable {
    var tracks: [SubtitleTrack] = []
    var modes: [Int: SubtitleMode] = [:]
    var text = ""

    func mode(for id: Int) -> SubtitleMode { modes[id] ?? .off }

    func canSet(_ mode: SubtitleMode, for track: SubtitleTrack) -> Bool {
        if mode == .off { return true }
        if mode == .plain && track.isImageBased { return false }
        let others = tracks.filter { $0.id != track.id && self.mode(for: $0.id) != .off }
        if others.count >= 2 { return false }
        return mode != .plain || !others.contains { self.mode(for: $0.id) == .plain }
    }

    mutating func set(_ mode: SubtitleMode, for track: SubtitleTrack) {
        guard canSet(mode, for: track) else { return }
        modes[track.id] = mode == .off ? nil : mode
    }

    static func initial(tracks: [SubtitleTrack], preferences: [String: SubtitlePreference]) -> Self {
        var state = Self(tracks: tracks)
        // Prefer a flagged track when a language has multiple variants. IDs are
        // never persisted: each new file supplies its own track identifiers.
        let ranked = tracks.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            if $0.isForced != $1.isForced { return $0.isForced }
            return $0.id < $1.id
        }
        let choices = preferences.map { key, value in
            (language: value.language ?? key, preference: value)
        }.sorted { $0.preference.order > $1.preference.order }
        var assigned = Set<Int>()
        var matchedOrders = Set<Int>()
        // Reserve exact language + label matches before language-only fallback.
        for exact in [true, false] {
            for choice in choices where !matchedOrders.contains(choice.preference.order) {
                let candidates = ranked.filter { $0.languageKey == choice.language && !assigned.contains($0.id) }
                let match = candidates.first {
                    (!exact || SubtitlePreferences.labelKey($0.title) == (choice.preference.label ?? "")) &&
                    state.canSet(choice.preference.mode, for: $0)
                }
                guard let match else { continue }
                state.set(choice.preference.mode, for: match)
                assigned.insert(match.id)
                matchedOrders.insert(choice.preference.order)
            }
        }
        if !state.modes.values.contains(.plain), let fallback = ranked.first(where: { track in
            !track.isImageBased && (track.isDefault || track.isForced) &&
            !choices.contains(where: { $0.language == track.languageKey }) && state.canSet(.plain, for: track)
        }) {
            state.set(.plain, for: fallback)
        }
        return state
    }
}




nonisolated struct AudioTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let language: String
    let isDefault: Bool
    var codec: String = ""
    var channelLayout: String = ""
    var details: String {
        [languageKey == nil ? "" : language, codec.uppercased(), channelLayout]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var label: String { title.isEmpty ? String(localized: "Audio \(id)") : title }
    var languageKey: String? { SubtitleLanguage.key(language) }
}

nonisolated struct AudioSelection: Codable, Equatable, Sendable {
    let language: String
    let label: String
    var id: Int? = nil

    init(_ track: AudioTrack) {
        language = track.languageKey ?? ""
        label = SubtitlePreferences.labelKey(track.title)
        id = track.id
    }
    func match(in tracks: [AudioTrack]) -> AudioTrack? {
        let candidates = tracks.filter { ($0.languageKey ?? "") == language }
            .sorted { $0.isDefault != $1.isDefault ? $0.isDefault : $0.id < $1.id }
        let exact = candidates.filter { SubtitlePreferences.labelKey($0.title) == label }
        return exact.first(where: { $0.id == id }) ?? exact.first ?? candidates.first
    }
}

nonisolated struct AudioState: Equatable, Sendable {
    var tracks: [AudioTrack] = []
    var selectedID: Int?
    var selection: AudioSelection? { tracks.first { $0.id == selectedID }.map(AudioSelection.init) }
}

nonisolated final class AudioPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [AudioSelection] {
        guard let data = defaults.data(forKey: "audioLanguagePreferences.v1") else { return [] }
        return (try? JSONDecoder().decode([AudioSelection].self, from: data)) ?? []
    }
    func save(_ track: AudioTrack) {
        guard track.languageKey != nil else { return }
        var selection = AudioSelection(track)
        selection.id = nil // IDs only have meaning in per-file history.
        var choices = load().filter { $0.language != selection.language }
        choices.insert(selection, at: 0)
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: "audioLanguagePreferences.v1") }
    }
    func match(in tracks: [AudioTrack]) -> AudioTrack? {
        load().lazy.compactMap { $0.match(in: tracks) }.first
    }
}
