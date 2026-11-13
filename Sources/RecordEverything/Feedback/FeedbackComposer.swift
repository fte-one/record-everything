import AppKit
import CoreGraphics

/// The finished feedback: a folder with `feedback.md` and numbered screenshots.
struct FeedbackResult {
    struct Image {
        let number: Int
        let file: URL
        let shot: FeedbackShot
    }

    let folder: URL
    let markdownFile: URL
    var markdown: String
    let images: [Image]
    let taskCount: Int
    let duration: TimeInterval
    /// Set when the AI summary was not available and the prompt is the plain protocol.
    let warning: String?
    /// Attachments: pasting puts the images into the input field before the prompt.
    var imageMode: FeedbackImageMode = .paths
}

/// Turns a recorded session into a prompt for a coding agent. An AI model (OpenRouter) reads the timeline and
/// the candidate stills, writes the tasks and picks the screenshots; the app numbers and marks the screenshots
/// and writes the Markdown itself, so every path and reference is right. Without the AI the prompt is the
/// timeline of what was said, with the screenshot nearest to each piece.
enum FeedbackComposer {
    struct Options {
        var model: String
        var maxImages: Int
        var extraInstructions: String
        var outputRoot: URL
        var imageMode: FeedbackImageMode = .attachments
        /// Off: only the user's own screenshots go into the prompt (when there are any).
        var autoShots = false
    }

    /// Most stills the AI gets to choose from.
    static let candidateLimit = 36

    struct PlanTask: Equatable {
        var title: String
        var description: String
        var url: String?
        var images: [Int]
        var quotes: [String]
    }

    struct Plan: Equatable {
        var title: String
        var summary: String
        var tasks: [PlanTask]
        var questions: [String]
    }

    static func compose(_ recording: FeedbackRecording, options: Options) async -> FeedbackResult? {
        // The user's own screenshots are what they meant; the automatic ones are only the fallback.
        let manual = recording.shots.filter(\.isManual)
        let manualOnly = !options.autoShots && !manual.isEmpty
        let candidates = manualOnly ? Array(manual.prefix(max(options.maxImages, 1))) : selectCandidates(recording)
        var plan: Plan?
        var warning: String?
        if recording.speech.isEmpty && candidates.isEmpty {
            warning = L("Nothing was recorded.")
        } else {
            do {
                plan = try await askAI(recording, candidates: candidates, manualOnly: manualOnly, options: options)
            } catch {
                warning = String(format: L("The AI summary failed (%@). Below is the protocol of the session."), error.localizedDescription)
            }
        }
        if !recording.speechErrors.isEmpty {
            let note = String(format: L("%d pieces of speech could not be transcribed."), recording.speechErrors.count)
            warning = [warning, note].compactMap { $0 }.joined(separator: " ")
        }

        // Number the screenshots in the order the prompt refers to them.
        var order: [Int] = []
        func use(_ id: Int) {
            guard !order.contains(id), order.count < options.maxImages, candidates.contains(where: { $0.id == id }) else { return }
            order.append(id)
        }
        if manualOnly {
            candidates.forEach { use($0.id) }   // every screenshot the user took
        } else if let plan {
            for task in plan.tasks { task.images.forEach(use) }
        } else {
            for part in recording.speech { if let shot = nearestShot(to: part, in: candidates) { use(shot.id) } }
            if order.isEmpty { candidates.filter { $0.kind != .change }.prefix(options.maxImages).forEach { use($0.id) } }
        }
        // Numbers follow the recording: Bild 3 is the third moment shown.
        let time = Dictionary(candidates.map { ($0.id, $0.time) }, uniquingKeysWith: { a, _ in a })
        order.sort { (time[$0] ?? 0, $0) < (time[$1] ?? 0, $1) }

        guard let folder = makeOutputFolder(options.outputRoot, date: recording.startDate) else { return nil }
        var images: [FeedbackResult.Image] = []
        for (index, id) in order.enumerated() {
            guard let shot = candidates.first(where: { $0.id == id }), let base = ImageFiles.load(shot.file),
                  let marked = render(base, marker: shot.marker, number: index + 1),
                  let data = ImageFiles.png(marked) else { continue }
            let file = folder.appendingPathComponent(String(format: "%02d.png", index + 1))
            guard (try? data.write(to: file)) != nil else { continue }
            images.append(.init(number: index + 1, file: file, shot: shot))
        }

        let markdown = writeMarkdown(recording, plan: plan, images: images, options: options, folder: folder, warning: warning)
        let markdownFile = folder.appendingPathComponent("feedback.md")
        try? markdown.write(to: markdownFile, atomically: true, encoding: .utf8)
        let title = plan?.title.isEmpty == false ? plan!.title : recording.windowTitle
        let meta = FeedbackMeta(title: title, date: recording.startDate, duration: recording.duration, taskCount: plan?.tasks.count ?? 0,
                                warning: warning, imageMode: options.imageMode,
                                images: images.map { .init(number: $0.number, file: $0.file.lastPathComponent, time: $0.shot.time,
                                                           url: $0.shot.url, title: $0.shot.title) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(meta).write(to: folder.appendingPathComponent(FeedbackMeta.fileName))
        return FeedbackResult(folder: folder, markdownFile: markdownFile, markdown: markdown, images: images,
                              taskCount: plan?.tasks.count ?? 0, duration: recording.duration, warning: warning,
                              imageMode: options.imageMode)
    }

    // MARK: Candidates

    /// The stills worth showing the AI: everything the user pointed at, and the views they talked about.
    static func selectCandidates(_ recording: FeedbackRecording) -> [FeedbackShot] {
        let shots = recording.shots
        guard shots.count > candidateLimit else { return shots }
        func score(_ shot: FeedbackShot) -> Int {
            var s: Int
            switch shot.kind {
            case .mark, .drawing: s = 40
            case .selection: s = 30
            case .hover: s = 18
            case .click: s = 20
            case .start: s = 15
            case .change: s = 10
            }
            if recording.speech.contains(where: { $0.start - 3 <= shot.time && shot.time <= $0.end + 3 }) { s += 12 }
            return s
        }
        let ranked = shots.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        return ranked.prefix(candidateLimit).map(\.element).sorted { $0.time < $1.time }
    }

    /// The still that best shows what a piece of speech is about: one the user pointed at while talking (closest
    /// to the middle of the piece), else the view on screen when they started.
    static func nearestShot(to part: FeedbackSpeech, in shots: [FeedbackShot]) -> FeedbackShot? {
        let middle = (part.start + part.end) / 2
        let pointed = shots.filter { $0.time >= part.start - 0.5 && $0.time <= part.end + 1.5 && rank($0.kind) > 1 }
        if let best = pointed.min(by: { a, b in
            rank(a.kind) != rank(b.kind) ? rank(a.kind) > rank(b.kind) : abs(a.time - middle) < abs(b.time - middle)
        }) { return best }
        return shots.last(where: { $0.time <= part.start + 1 })
            ?? shots.first(where: { $0.time >= part.start - 0.5 && $0.time <= part.end + 1.5 }) ?? shots.first
    }

    /// Splits what was said among the pictures: each piece belongs to the first picture taken no more than three
    /// seconds before it began (people keep talking while and just after they take one). The rest came after.
    static func speechGroups(_ shots: [FeedbackShot], _ speech: [FeedbackSpeech]) -> [(shot: FeedbackShot?, parts: [FeedbackSpeech])] {
        let sorted = shots.sorted { $0.time < $1.time }
        var groups: [(shot: FeedbackShot?, parts: [FeedbackSpeech])] = sorted.map { ($0, []) }
        var rest: [FeedbackSpeech] = []
        for part in speech.sorted(by: { $0.start < $1.start }) {
            if let index = sorted.firstIndex(where: { $0.time + 3 >= part.start }) {
                groups[index].parts.append(part)
            } else {
                rest.append(part)
            }
        }
        if !rest.isEmpty { groups.append((nil, rest)) }
        return groups
    }

    private static func rank(_ kind: FeedbackShot.Kind) -> Int {
        switch kind {
        case .mark, .drawing: return 4
        case .selection: return 3
        case .click, .hover: return 2
        case .start, .change: return 1
        }
    }

    // MARK: AI

    static let systemPrompt = """
    Du bekommst die Aufzeichnung einer Feedback-Session: Jemand klickt sich durch eine Anwendung (meist eine Web-App \
    im Browser) und sagt dabei laut, was geändert werden soll. Mach daraus einen klaren Arbeitsauftrag für einen \
    KI-Coding-Agenten, der den Code ändert.

    Regeln:
    - Jede gewünschte Änderung ist eine Aufgabe. Fasse Zusammengehöriges zusammen, lass Wiederholungen, Füllwörter, \
    Versprecher und Selbstkorrekturen weg (es gilt die letzte Fassung).
    - Sei konkret: Auf welcher Seite (URL), welches Element (so beschrieben, dass man es im Code findet: Beschriftung, \
    Position, Farbe, Art), was ist jetzt falsch, was soll stattdessen sein.
    - Erfinde nichts. Was sich aus der Aufnahme nicht klar ergibt, kommt als offene Frage.
    - Das Transkript stammt aus einer Spracherkennung und kann Hörfehler enthalten (z. B. "Sportschau" statt \
    "Sport-Show"). Korrigiere sie anhand der Beschriftungen auf den Bildern und nenne Elemente so, wie sie dort stehen.
    - "hier", "das da", "dieser": gemeint ist die markierte Stelle im Bild zu diesem Zeitpunkt.
    - Bilder, die "vom Nutzer aufgenommen" sind, hat er bewusst gemacht: Jedes davon gehört zu mindestens einer \
    Aufgabe. Was er seit dem vorigen Bild bis wenige Sekunden danach sagt, bezieht sich auf dieses Bild (siehe \
    "Gesagtes je Bild"). Rote Linien hat er selbst gezeichnet, um die gemeinte Stelle zu zeigen.
    - Bilder: Gib pro Aufgabe die 1 bis 3 aussagekräftigsten Bilder an (Kennungen wie "K12"). Rote Kreise sind \
    Klickstellen, gelbe Kreise die Stelle, auf die die Maus beim Sprechen zeigte, rote Rahmen markierte Bereiche. \
    Nutze vor allem Bilder, auf die sich das Gesagte bezieht.
    - summary: nur worum es insgesamt geht, sachlich und ohne Bewertung der Aussagen. Unklares gehört in questions.
    - quotes: kurze wörtliche Zitate des Gesagten, wenn sie die Absicht klarer machen.
    - Schreib auf Deutsch.

    Antworte nur mit JSON in dieser Form, ohne weiteren Text:
    {"title": "kurzer Titel der Session", "summary": "1–3 Sätze: worum es insgesamt geht", \
    "tasks": [{"title": "kurz", "description": "konkret, was zu tun ist", "url": "Seite oder null", \
    "images": ["K3"], "quotes": ["…"]}], "questions": ["offene Frage"]}
    """

    static func timeline(_ recording: FeedbackRecording, candidates: [FeedbackShot], manualOnly: Bool = false) -> String {
        var lines: [(TimeInterval, Int, String)] = []
        for page in recording.pages {
            let title = page.title.isEmpty ? "" : "\(page.title) – "
            lines.append((page.time, 0, "[\(feedbackClock(page.time))] Seite: \(title)\(page.url ?? "(keine URL)")"))
        }
        for shot in candidates {
            var line = "[\(feedbackClock(shot.time))] \(shot.key): "
            switch shot.kind {
            case .start: line += "Start der Session"
            case .click: line += "Klick (roter Kreis)"
            case .selection: line += "Bereich markiert (roter Rahmen)" + (shot.selectedText.map { ", markierter Text: „\($0)“" } ?? "")
            case .mark: line += "vom Nutzer aufgenommen"
            case .drawing: line += "vom Nutzer aufgenommen und mit roter Linie markiert"
            case .hover: line += "Maus zeigt beim Sprechen hierhin (gelber Kreis)"
            case .change: line += "Ansicht hat sich geändert"
            }
            lines.append((shot.time, 1, line))
        }
        if manualOnly {
            // Clicks and selections without a picture still tell where the user was.
            for shot in recording.shots where !shot.isManual {
                switch shot.kind {
                case .click: lines.append((shot.time, 1, "[\(feedbackClock(shot.time))] Klick (ohne Bild)"))
                case .selection:
                    if let text = shot.selectedText { lines.append((shot.time, 1, "[\(feedbackClock(shot.time))] Text markiert: „\(text)“")) }
                default: break
                }
            }
        }
        for part in recording.speech {
            lines.append((part.start, 2, "[\(feedbackClock(part.start))–\(feedbackClock(part.end))] Gesagt: „\(part.text)“"))
        }
        return lines.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2).joined(separator: "\n")
    }

    static func askAI(_ recording: FeedbackRecording, candidates: [FeedbackShot], manualOnly: Bool, options: Options) async throws -> Plan {
        var perImage = ""
        if manualOnly {
            let groups = speechGroups(candidates, recording.speech)
            perImage = "\n\nGesagtes je Bild:\n" + groups.map { group in
                let said = group.parts.map { "„\($0.text)“" }.joined(separator: " ")
                return "\(group.shot.map(\.key) ?? "nach dem letzten Bild"): \(said.isEmpty ? "(nichts)" : said)"
            }.joined(separator: "\n")
        }
        var content: [[String: Any]] = [[
            "type": "text",
            "text": """
            Session: \(feedbackClock(recording.duration)) Min., App: \(recording.appName), Fenster: \(recording.windowTitle)

            Zeitleiste:
            \(timeline(recording, candidates: candidates, manualOnly: manualOnly))\(perImage)

            Es folgen die Bilder mit ihren Kennungen.
            """,
        ]]
        for shot in candidates {
            guard let base = ImageFiles.load(shot.file), let marked = render(base, marker: shot.marker, number: nil),
                  let small = scaled(marked, maxSide: 1400), let jpeg = ImageFiles.jpeg(small, quality: 0.7) else { continue }
            content.append(["type": "text", "text": "\(shot.key) (\(feedbackClock(shot.time)))"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        let answer = try await OpenRouter.chat(model: options.model, system: systemPrompt, content: content, maxTokens: 6000)
        guard let plan = parsePlan(answer) else {
            throw OpenRouter.Failure(message: L("the answer could not be read."))
        }
        return plan
    }

    /// Reads the AI's JSON, tolerating a code fence or text around it.
    static func parsePlan(_ answer: String) -> Plan? {
        guard let open = answer.firstIndex(of: "{"), let close = answer.lastIndex(of: "}"), open < close,
              let data = String(answer[open...close]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ any: Any?) -> String? {
            guard let s = any as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.lowercased() == "null" ? nil : t
        }
        func imageID(_ any: Any) -> Int? {
            if let n = any as? Int { return n }
            guard let s = any as? String else { return nil }
            return Int(s.filter(\.isNumber))
        }
        let tasks: [PlanTask] = (json["tasks"] as? [[String: Any]] ?? []).compactMap { t in
            guard let title = string(t["title"]) else { return nil }
            return PlanTask(title: title, description: string(t["description"]) ?? "", url: string(t["url"]),
                        images: (t["images"] as? [Any] ?? []).compactMap(imageID),
                        quotes: (t["quotes"] as? [Any] ?? []).compactMap(string))
        }
        return Plan(title: string(json["title"]) ?? "", summary: string(json["summary"]) ?? "", tasks: tasks,
                    questions: (json["questions"] as? [Any] ?? []).compactMap(string))
    }

    // MARK: Markdown

    static func writeMarkdown(_ recording: FeedbackRecording, plan: Plan?, images: [FeedbackResult.Image], options: Options,
                              folder: URL, warning: String?) -> String {
        let byShot = Dictionary(images.map { ($0.shot.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Tasks and protocol say "Bild 3"; the list of images maps each number to its file once.
        func link(_ image: FeedbackResult.Image) -> String { "Bild \(image.number)" }
        let date = DateFormatter.localizedString(from: recording.startDate, dateStyle: .medium, timeStyle: .short)
        var md: [String] = []

        let title = plan?.title.isEmpty == false ? plan!.title : recording.windowTitle
        md.append("# Feedback: \(title)")
        md.append("")
        if let summary = plan?.summary, !summary.isEmpty { md.append(summary); md.append("") }
        md.append("> Aufgenommen am \(date) · \(feedbackClock(recording.duration)) Min. · \(recording.appName)")
        if !images.isEmpty {
            let legend = "Rote Linien habe ich selbst gezogen, um die gemeinte Stelle zu zeigen; rote Kreise sind Klicks, gelbe "
                + "Kreise zeigen, wohin die Maus beim Sprechen zeigte, rote Rahmen sind markierte Bereiche. "
                + "Sieh dir die Bilder an, bevor du etwas änderst."
            switch options.imageMode {
            case .attachments:
                md.append("> Die \(images.count) Screenshots hängen dieser Nachricht als Bilder an, in der Reihenfolge Bild 1 bis "
                          + "Bild \(images.count); die Nummer steht zusätzlich oben links im Bild. " + legend)
            case .paths:
                md.append("> Screenshots im Ordner `\(folder.path)`: Bild N ist `NN.png`, die Nummer steht oben links im Bild. " + legend)
            }
        }
        if let warning { md.append(">"); md.append("> ⚠️ \(warning)") }
        md.append("")

        if let plan, !plan.tasks.isEmpty {
            md.append("## Aufgaben")
            md.append("")
            for (i, task) in plan.tasks.enumerated() {
                md.append("### \(i + 1). \(task.title)")
                md.append("")
                if !task.description.isEmpty { md.append(task.description); md.append("") }
                if let url = task.url { md.append("- Seite: \(url)") }
                let refs = task.images.compactMap { byShot[$0] }.sorted { $0.number < $1.number }.map(link)
                if !refs.isEmpty { md.append("- Bilder: " + refs.joined(separator: ", ")) }
                for quote in task.quotes { md.append("- O-Ton: „\(quote)“") }
                md.append("")
            }
            if !plan.questions.isEmpty {
                md.append("## Offene Fragen")
                md.append("")
                plan.questions.forEach { md.append("- \($0)") }
                md.append("")
            }
        }

        let extra = options.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            md.append("## Zusatzanweisungen")
            md.append("")
            md.append(extra)
            md.append("")
        }

        if !images.isEmpty {
            // Each picture with what was said about it: readable on its own, also without the AI.
            md.append("## Bilder und was dazu gesagt wurde")
            md.append("")
            for group in speechGroups(images.map(\.shot), recording.speech) {
                if let shot = group.shot, let image = byShot[shot.id] {
                    var heading = "### Bild \(image.number) · \(feedbackClock(shot.time))"
                    if let url = shot.url { heading += " · \(url)" } else if let title = shot.title, !title.isEmpty { heading += " · \(title)" }
                    md.append(heading)
                    if options.imageMode == .paths { md.append("Datei: `\(image.file.path)`") }
                    if let text = shot.selectedText { md.append("Markiert: „\(text)“") }
                } else {
                    md.append("### Nach dem letzten Bild")
                }
                let said = group.parts.map { "„\($0.text)“" }.joined(separator: " ")
                md.append(said.isEmpty ? "(nichts gesagt)" : said)
                md.append("")
            }
        } else {
            md.append("## Protokoll")
            md.append("")
            if recording.speech.isEmpty { md.append("- (Nichts gesagt oder nicht in Text umgewandelt.)") }
            for part in recording.speech { md.append("- \(feedbackClock(part.start)) · „\(part.text)“") }
            md.append("")
        }

        var lastURL: String?
        var visited: [String] = []
        for page in recording.pages where page.url != lastURL || page.url == nil {
            lastURL = page.url
            let label = [page.title.isEmpty ? nil : page.title, page.url].compactMap { $0 }.joined(separator: " – ")
            if !label.isEmpty { visited.append("- \(feedbackClock(page.time)) · \(label)") }
        }
        if !visited.isEmpty {
            md.append("## Besuchte Seiten")
            md.append("")
            md.append(contentsOf: visited)
            md.append("")
        }
        return md.joined(separator: "\n")
    }

    // MARK: Images

    /// Draws the marker (click circle or selection frame) and, if given, the number badge in the top left.
    static func render(_ base: CGImage, marker: FeedbackShot.Marker?, number: Int?) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Work in top-left coordinates like the markers.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let unit = max(1, CGFloat(w) / 1400)
        let red = CGColor(srgbRed: 0.98, green: 0.22, blue: 0.2, alpha: 1)
        switch marker {
        case .click(let p):
            let r = 26 * unit
            ctx.setFillColor(red.copy(alpha: 0.18)!)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(red)
            ctx.setLineWidth(5 * unit)
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.setFillColor(red)
            ctx.fillEllipse(in: CGRect(x: p.x - 4 * unit, y: p.y - 4 * unit, width: 8 * unit, height: 8 * unit))
        case .ink(let points):
            guard points.count > 1 else { break }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setShadow(offset: .zero, blur: 4 * unit, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setStrokeColor(red)
            ctx.setLineWidth(5 * unit)
            ctx.addLines(between: points)
            ctx.strokePath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        case .pointer(let p):
            let yellow = CGColor(srgbRed: 1, green: 0.78, blue: 0.05, alpha: 1)
            let r = 24 * unit
            let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(yellow.copy(alpha: 0.2)!)
            ctx.fillEllipse(in: circle)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))   // dark rim: visible on light pages too
            ctx.setLineWidth(8 * unit)
            ctx.strokeEllipse(in: circle)
            ctx.setStrokeColor(yellow)
            ctx.setLineWidth(5 * unit)
            ctx.strokeEllipse(in: circle)
            ctx.setFillColor(yellow)
            ctx.fillEllipse(in: CGRect(x: p.x - 4 * unit, y: p.y - 4 * unit, width: 8 * unit, height: 8 * unit))
        case .selection(let rect):
            let r = rect.insetBy(dx: -6 * unit, dy: -6 * unit)
            ctx.setFillColor(red.copy(alpha: 0.08)!)
            ctx.fill(r)
            ctx.setStrokeColor(red)
            ctx.setLineWidth(4 * unit)
            ctx.stroke(r)
        case nil:
            break
        }
        if let number {
            let side = 46 * unit
            let badge = CGRect(x: 14 * unit, y: 14 * unit, width: side, height: side)
            ctx.setShadow(offset: .zero, blur: 6 * unit, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(red)
            ctx.fillEllipse(in: badge)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(3 * unit)
            ctx.strokeEllipse(in: badge.insetBy(dx: 1.5 * unit, dy: 1.5 * unit))
            let text = "\(number)" as NSString
            let font = NSFont.systemFont(ofSize: (number < 10 ? 26 : 21) * unit, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }

    static func scaled(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide else { return image }
        let f = maxSide / longest
        let w = Int(CGFloat(image.width) * f), h = Int(CGFloat(image.height) * f)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func makeOutputFolder(_ root: URL, date: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        var folder = root.appendingPathComponent("Feedback \(formatter.string(from: date))", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("Feedback \(formatter.string(from: date)) (\(n))", isDirectory: true)
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }
}
