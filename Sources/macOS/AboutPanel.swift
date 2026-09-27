import AetherEngine
import AppKit

/// The standard About panel, plus the one fact it cannot know by itself: which engine this build
/// embeds. AppKit fills name, version and copyright from the bundle, and the engine is not in the
/// bundle's vocabulary, so it goes in through the credits slot, directly under the version line.
@MainActor
enum AboutPanel {

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSMutableAttributedString(
            string: "Based on AetherPlayer and AetherEngine\nDesign based on VisionOS App Melon Video\n\nAetherEngine \(AetherEngine.version)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])

        let text = credits.string as NSString
        credits.addAttribute(.link, value: URL(string: "https://aetherengine.superuser404.de")!,
                             range: text.range(of: "AetherEngine"))
        credits.addAttribute(.link, value: URL(string: "https://apps.apple.com/us/app/melon-video/id6811750997")!,
                             range: text.range(of: "Melon Video"))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
