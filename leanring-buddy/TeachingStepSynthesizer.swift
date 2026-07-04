//
//  TeachingStepSynthesizer.swift
//  leanring-buddy
//
//  Turns raw capture (OCR, URLs, narration) into readable step labels.
//

import Foundation

enum TeachingStepSynthesizer {

    struct StepLabel: Equatable {
        let title: String
        let instruction: String
        let lookFor: String?
        let doneWhen: String?
    }

    // MARK: - Public

    static func label(
        segment: TeachingSegment,
        artifact: TeachingArtifact
    ) -> StepLabel {
        let narration = segment.narrations
            .map { cleanNarration($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let context = segment.context?.screenContext ?? ScreenContext(app: "Unknown", url: nil, windowTitle: nil)

        if !narration.isEmpty {
            return labelFromNarration(narration, context: context)
        }

        let keyframe = segment.keyframeID.flatMap { id in
            artifact.keyframes.first { $0.id == id }
        }
        let ocrTerms = keyframe.map { PinkyWorkflowOCR.recognizeTerms(from: $0.jpegData) } ?? []

        return labelFromContext(context, ocrTerms: ocrTerms)
    }

    static func cleanNarration(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            #"(?i)^okay[,\s]+(clicky|pinky|clickey)[,\s,-]*"#,
            #"(?i)^so[,\s]+"#,
            #"(?i)^and then[,\s]+"#,
            #"(?i)i'?m going to teach you (how )?(i )?(to )?"#,
            #"(?i)^the first thing you do is "#,
            #"\b(uh|um|er|like)\b"#,
        ]

        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func stepTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Step" }

        if let sentenceEnd = trimmed.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let first = String(trimmed[..<sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if first.count >= 8 && first.count <= 64 {
                return first
            }
        }

        if trimmed.count <= 56 { return trimmed }
        return String(trimmed.prefix(56)) + "…"
    }

    static func filterOCRTerms(_ terms: [String]) -> [String] {
        terms.filter { term in
            let token = term.lowercased()
            guard token.count >= 4 else { return false }
            guard !browserChromeNoise.contains(token) else { return false }
            guard !looksLikeOCRGarbage(token) else { return false }
            return true
        }
    }

    static func urlPathSignature(_ rawURL: String?) -> String? {
        guard
            let rawURL,
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let host = url.host?.lowercased()
        else {
            return nil
        }

        let path = url.path.lowercased()
        if path.isEmpty || path == "/" { return "\(host)/" }

        let markers = ["search", "shop", "product", "basket", "cart", "checkout", "account", "login"]
        for marker in markers where path.contains(marker) {
            if marker == "search", let query = searchQuery(from: url) {
                return "\(host)/search?q=\(query)"
            }
            return "\(host)/\(marker)"
        }

        let components = path.split(separator: "/").prefix(2).joined(separator: "/")
        return "\(host)/\(components)"
    }

    // MARK: - Private

    private static let browserChromeNoise: Set<String> = [
        "file", "history", "bookmark", "bookmarks", "profiles", "profile", "help",
        "window", "view", "edit", "chrome", "chromium", "safari", "firefox",
        "tab", "tabs", "tools", "settings", "menu", "close", "minimize", "maximize",
    ]

    private static func labelFromNarration(_ narration: String, context: ScreenContext) -> StepLabel {
        let title = stepTitle(from: narration)
        let lookFor = extractLookFor(from: narration) ?? navigationLabel(from: context)?.lookFor
        let doneWhen = inferDoneWhen(from: narration, context: context)

        return StepLabel(
            title: title,
            instruction: narration,
            lookFor: lookFor,
            doneWhen: doneWhen
        )
    }

    private static func labelFromContext(_ context: ScreenContext, ocrTerms: [String]) -> StepLabel {
        if let navigation = navigationLabel(from: context) {
            return navigation
        }

        let filtered = filterOCRTerms(ocrTerms)
        if !filtered.isEmpty {
            let hint = filtered.prefix(3).joined(separator: ", ")
            return StepLabel(
                title: meaningfulWindowTitle(context.windowTitle) ?? context.app,
                instruction: "In \(context.app), look for \(hint).",
                lookFor: filtered.first,
                doneWhen: nil
            )
        }

        let fallbackTitle = meaningfulWindowTitle(context.windowTitle) ?? context.app
        return StepLabel(
            title: fallbackTitle,
            instruction: "Continue in \(context.app).",
            lookFor: fallbackTitle,
            doneWhen: nil
        )
    }

    private static func navigationLabel(from context: ScreenContext) -> StepLabel? {
        guard
            let rawURL = context.url,
            !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let host = url.host?.lowercased()
        else {
            if let title = meaningfulWindowTitle(context.windowTitle) {
                return StepLabel(
                    title: title,
                    instruction: "Work in \(title).",
                    lookFor: title,
                    doneWhen: nil
                )
            }
            return nil
        }

        let site = siteDisplayName(from: host)
        let path = url.path.lowercased()

        if path.isEmpty || path == "/" || rawURL.lowercased().contains("newtab") {
            return StepLabel(
                title: "Open \(site)",
                instruction: "Go to \(site) (\(host)).",
                lookFor: site,
                doneWhen: "The \(site) homepage is visible."
            )
        }

        if path.contains("search") {
            if let query = searchQuery(from: url) {
                return StepLabel(
                    title: "Search for \(query)",
                    instruction: "Search \(site) for \"\(query)\".",
                    lookFor: "search",
                    doneWhen: "Search results for \(query) are visible."
                )
            }
            return StepLabel(
                title: "Search \(site)",
                instruction: "Use the search on \(site).",
                lookFor: "search",
                doneWhen: "Search results are visible."
            )
        }

        if path.contains("shop") || path.contains("product") {
            return StepLabel(
                title: "Choose a product",
                instruction: "Open a product page on \(site).",
                lookFor: "Add to basket",
                doneWhen: "A product detail page is open."
            )
        }

        if path.contains("basket") || path.contains("cart") {
            return StepLabel(
                title: "Review basket",
                instruction: "Open your shopping basket on \(site).",
                lookFor: "basket",
                doneWhen: "The basket or cart page is visible."
            )
        }

        if path.contains("checkout") {
            return StepLabel(
                title: "Checkout",
                instruction: "Proceed to checkout on \(site).",
                lookFor: "checkout",
                doneWhen: "The checkout page is visible."
            )
        }

        return StepLabel(
            title: site,
            instruction: "Continue on \(host)\(url.path).",
            lookFor: site,
            doneWhen: nil
        )
    }

    private static func siteDisplayName(from host: String) -> String {
        let bare = host.replacingOccurrences(of: "www.", with: "")
        let namePart = bare.split(separator: ".").first.map(String.init) ?? bare
        let spaced = namePart.replacingOccurrences(
            of: #"([a-z])([A-Z])|([a-z])(\d)|(\d)([a-z])"#,
            with: "$1 $2$3$4$5$6",
            options: .regularExpression
        )

        if spaced.contains(" ") {
            return spaced.capitalized
        }

        // hollandandbarrett -> Holland and Barrett (best effort for known compound names)
        if bare.contains("hollandandbarrett") { return "Holland and Barrett" }

        return bare
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func searchQuery(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems?
            .first(where: { ["q", "query", "search", "term"].contains($0.name.lowercased()) })?
            .value?
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else { return nil }
        return query
    }

    private static func meaningfulWindowTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        let lowered = title.lowercased()
        if lowered == "google chrome" || lowered == "safari" || lowered == "new tab" || lowered == "start page" {
            return nil
        }

        for suffix in [" - Google Chrome", " — Google Chrome", " - Safari"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
                break
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func extractLookFor(from narration: String) -> String? {
        let lowered = narration.lowercased()
        let keywords = [
            "holland and barrett": "Holland and Barrett",
            "checkout": "checkout",
            "basket": "basket",
            "cart": "cart",
            "search": "search",
            "protein powder": "protein powder",
        ]
        for (needle, label) in keywords where lowered.contains(needle) {
            return label
        }
        return nil
    }

    private static func inferDoneWhen(from narration: String, context: ScreenContext) -> String? {
        let lowered = narration.lowercased()
        if lowered.contains("go to checkout") || lowered.contains("press go to checkout") {
            return "The checkout page is visible."
        }
        if lowered.contains("holland and barrett") {
            return "The Holland and Barrett site is open."
        }
        return navigationLabel(from: context)?.doneWhen
    }

    private static func looksLikeOCRGarbage(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter).count
        let digits = token.filter(\.isNumber).count

        if digits > 0 && letters > 0 && token.count <= 10 { return true }

        let vowels = token.filter { "aeiou".contains($0) }.count
        if token.count >= 5 && vowels == 0 { return true }
        if token.count >= 6 && Double(vowels) / Double(token.count) < 0.15 { return true }

        return false
    }
}
