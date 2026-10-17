import AppKit

/// Publisher details, matching the fte.one website.
enum Brand {
    static let copyright = "© 2026 fte.one c/o OK Venture GmbH"
    static let website = URL(string: "https://fte.one")!

    /// Imprint page in the app's language (the site offers en, de, fr, es, pt, it).
    static var imprintURL: URL {
        let lang = Bundle.main.preferredLocalizations.first?.prefix(2).lowercased() ?? "en"
        let supported = ["en", "de", "fr", "es", "pt", "it"]
        return URL(string: "https://fte.one/\(supported.contains(lang) ? lang : "en")/impressum/")!
    }

    /// About panel with the fte.one claim and links to the website and the imprint.
    @MainActor
    static func showAbout() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: L("Crafted by humans & agents") + "\n", attributes: base)
        credits.append(NSAttributedString(string: "fte.one", attributes: base.merging([.link: website]) { $1 }))
        credits.append(NSAttributedString(string: "  ·  ", attributes: base))
        credits.append(NSAttributedString(string: L("Imprint"), attributes: base.merging([.link: imprintURL]) { $1 }))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
