import XCTest
import libass
import AetherEngine
@testable import AetherPlayer

final class TrackMenuModelTests: XCTestCase {
    private func audio(_ id: Int, _ name: String, lang: String? = nil, ch: Int = 2, atmos: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: name, codec: "eac3", language: lang, channels: ch, isDefault: false, isAtmos: atmos)
    }

    func testAudioRowLabelsIncludeLanguageAndChannels() {
        let rows = audioMenuRows([audio(0, "English", lang: "en", ch: 6)], activeIndex: 0)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "English · EN · 5.1")
        XCTAssertTrue(rows[0].isSelected)
        XCTAssertEqual(rows[0].engineIndex, 0)
    }

    func testAtmosOverridesChannelLabel() {
        let rows = audioMenuRows([audio(0, "Surround", lang: "en", ch: 6, atmos: true)], activeIndex: nil)
        XCTAssertEqual(rows[0].label, "Surround · EN · Atmos")
        XCTAssertFalse(rows[0].isSelected)
    }

    func testStereoAndUnknownChannelLabels() {
        XCTAssertEqual(audioMenuRows([audio(0, "A", ch: 2)], activeIndex: nil)[0].label, "A · Stereo")
        XCTAssertEqual(audioMenuRows([audio(0, "B", ch: 8)], activeIndex: nil)[0].label, "B · 7.1")
    }

    func testSubtitleRowsPrependOffAndMarkSelection() {
        let subs = [TrackInfo(id: 3, name: "English", codec: "subrip", language: "en", channels: 0, isDefault: false)]
        let off = subtitleMenuRows(subs, selectedEngineIndex: nil, isActive: false)
        XCTAssertEqual(off.first?.kind, .off)
        XCTAssertTrue(off.first!.isSelected)
        let on = subtitleMenuRows(subs, selectedEngineIndex: 3, isActive: true)
        XCTAssertFalse(on.first!.isSelected)
        XCTAssertEqual(on.last?.label, "English · EN")
        XCTAssertTrue(on.last!.isSelected)
    }

    func testTitleRowsLabelAndSelection() {
        let titles = [
            TitleInfo(id: 0, name: "Title 1", durationSeconds: 7325, chapterCount: 12),
            TitleInfo(id: 1, name: "Title 2", durationSeconds: 0, chapterCount: 0),
        ]
        let rows = titleMenuRows(titles, selectedID: 0)
        XCTAssertEqual(rows[0].label, "Title 1 · 2:02:05 · 12 ch")
        XCTAssertTrue(rows[0].isSelected)
        XCTAssertEqual(rows[1].label, "Title 2")          // no duration / chapters -> name only
        XCTAssertFalse(rows[1].isSelected)
    }

    func testChapterRowsLabel() {
        let chapters = [
            ChapterInfo(id: 0, name: "Chapter 1", startSeconds: 0, durationSeconds: 600),
            ChapterInfo(id: 1, name: "Chapter 2", startSeconds: 754, durationSeconds: 600),
        ]
        let rows = chapterMenuRows(chapters)
        XCTAssertEqual(rows.map(\.id), [0, 1])
        XCTAssertEqual(rows[0].label, "Chapter 1 · 0:00:00")
        XCTAssertEqual(rows[1].label, "Chapter 2 · 0:12:34")
    }
}

extension TrackMenuModelTests {
    func testMelonPreferencesMatchLanguageAliasesAndTrackLabels() {
        let name = "AetherPlayer.TrackPreferences.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SubtitlePreferences(defaults: defaults)
        preferences.save(.off, language: "jpn", label: "Signs & Lyrics")
        preferences.save(.plain, language: "ja", label: "Dialog")
        let tracks = [
            SubtitleTrack(id: 18, title: "Signs & Lyrics", language: "ja", codec: "ass", isDefault: true),
            SubtitleTrack(id: 23, title: "Dialog", language: "jpn", codec: "ass")
        ]
        let restored = SubtitleState.initial(tracks: tracks, preferences: preferences.load())
        XCTAssertEqual(restored.mode(for: 18), .off)
        XCTAssertEqual(restored.mode(for: 23), .plain)
        XCTAssertEqual(SubtitleLanguage.key("chi"), SubtitleLanguage.key("zh"))
        XCTAssertEqual(SubtitleLanguage.key("eng"), "en")
        XCTAssertNotEqual(SubtitleLanguage.key("zh-Hant"), SubtitleLanguage.key("zh-Hans"))

        let audio = AudioPreferences(defaults: defaults)
        audio.save(AudioTrack(id: 1, title: "Main", language: "jpn", isDefault: false))
        let candidates = [AudioTrack(id: 9, title: "Commentary", language: "ja", isDefault: true),
                          AudioTrack(id: 11, title: "Main", language: "ja", isDefault: false)]
        XCTAssertEqual(audio.match(in: candidates)?.id, 11)
        XCTAssertNil(audio.load().first?.id, "Stream IDs must not persist across files")
    }

    func testDefaultSubtitleRoleAndExplicitOff() {
        let tracks = [SubtitleTrack(id: 1, title: "English", language: "eng", codec: "subrip", isForced: true)]
        XCTAssertEqual(SubtitleState.initial(tracks: tracks, preferences: [:]).mode(for: 1), .plain)
        let off = ["en": SubtitlePreference(mode: .off, order: 1)]
        XCTAssertEqual(SubtitleState.initial(tracks: tracks, preferences: off).mode(for: 1), .off)
        let bitmap = SubtitleTrack(id: 2, title: "PGS", language: "en", codec: "hdmv_pgs_subtitle")
        XCTAssertFalse(SubtitleState(tracks: [bitmap]).canSet(.plain, for: bitmap))
    }
}


extension TrackMenuModelTests {
    func testPlainSubtitleStripsASSStylesAndDrawing() {
        XCTAssertEqual(AetherSubtitleText.plain("0,0,Default,,0,0,0,,{\\b1}Hello\\Nworld"), "Hello\nworld")
        XCTAssertEqual(AetherSubtitleText.plain("0,0,Default,,0,0,0,,{\\p1}m 0 0 l 20 20{\\p0}Text"), "Text")
    }

    @MainActor func testDirectASSRendererDisplaysAndClearsCue() async {
        let worker = ASSFrameWorker()
        let header = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,32,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        worker.update(header: header, trackID: 1, fonts: [], cues: [ASSEvent(startTime: 1, endTime: 2, text: "0,0,Default,,0,0,0,,Hello")])
        let image = await withCheckedContinuation { continuation in
            worker.render(time: 1.5, size: CGSize(width: 640, height: 360)) { image, _ in continuation.resume(returning: image) }
        }
        XCTAssertEqual(image?.width, 640)
        XCTAssertEqual(image?.height, 360)
        let cleared = await withCheckedContinuation { continuation in
            worker.render(time: 3, size: CGSize(width: 640, height: 360)) { image, changed in
                continuation.resume(returning: image == nil && changed)
            }
        }
        XCTAssertTrue(cleared)
        worker.reset()
    }
}


extension TrackMenuModelTests {
    func testASSMaskCoverageAndOpacity() {
        var coverage: [UInt8] = [0, 255]
        coverage.withUnsafeMutableBufferPointer { bytes in
            var glyph = ASS_Image()
            glyph.w = 2; glyph.h = 1; glyph.stride = 2
            glyph.bitmap = bytes.baseAddress
            glyph.color = 0xFF00007F // red, approximately half opacity
            let image = withUnsafeMutablePointer(to: &glyph) { ASSFrameWorker.compose($0, width: 2, height: 1) }
            XCTAssertNotNil(image)
            guard let image else { return }
            var pixels = [UInt8](repeating: 0, count: 8)
            pixels.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: 2, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
            }
            XCTAssertEqual(pixels[3], 0)
            XCTAssertEqual(Int(pixels[7]), 128, accuracy: 1)
            XCTAssertEqual(Int(pixels[4]), 128, accuracy: 1)
            XCTAssertEqual(pixels[5], 0)
            XCTAssertEqual(pixels[6], 0)
        }
    }
}
