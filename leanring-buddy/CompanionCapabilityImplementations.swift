//
//  CompanionCapabilityImplementations.swift
//  leanring-buddy
//
//  Concrete act/observe capabilities registered with the agent.
//

import AppKit
import Foundation

// MARK: - Point

struct CompanionPointAtElementCapability: CompanionCapability {
    let name = "point_at_element"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent, .guideStep]

    let toolDefinition: [String: Any] = [
        "name": "point_at_element",
        "description": """
        Point Pinky's on-screen cursor at a UI element to help the user navigate. \
        Use when showing where to click would help. Coordinates are in screenshot pixel space \
        (origin top-left; dimensions are in the image label).
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "x": [
                    "type": "integer",
                    "description": "Horizontal pixel coordinate in the screenshot",
                ],
                "y": [
                    "type": "integer",
                    "description": "Vertical pixel coordinate in the screenshot",
                ],
                "label": [
                    "type": "string",
                    "description": "Short 1-3 word description of the element",
                ],
            ],
            "required": ["x", "y", "label"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let x = CompanionCapabilityInput.intValue(input["x"]),
              let y = CompanionCapabilityInput.intValue(input["y"]) else {
            return .failure("invalid coordinates")
        }

        let label = CompanionCapabilityInput.trimmedString(input["label"]) ?? "element"
        var effects = CompanionTurnEffects()
        effects.pointTarget = CompanionPointTarget(x: x, y: y, label: label)
        return .success("pointed at \(label)", effects: effects)
    }
}

// MARK: - Present

struct CompanionShowPanelCapability: CompanionCapability {
    let name = "show_panel"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "show_panel",
        "description": """
        Open a floating panel with a stock chart or Google Maps view when a visual panel \
        would genuinely help answer the question.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["stock", "places"],
                    "description": "stock for share prices; places for local lookups",
                ],
                "query": [
                    "type": "string",
                    "description": "Ticker symbol (e.g. AAPL) or short maps search query",
                ],
            ],
            "required": ["kind", "query"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        let kind = CompanionCapabilityInput.trimmedString(input["kind"])?.lowercased() ?? ""
        guard let query = CompanionCapabilityInput.trimmedString(input["query"]) else {
            return .failure("missing panel query")
        }

        let payload: PinkyWebResultPayload?
        switch kind {
        case "stock":
            payload = PinkyWebResultPayloadBuilder.stockChart(ticker: query)
        case "places":
            payload = PinkyWebResultPayloadBuilder.placesMap(searchQuery: query)
        default:
            payload = nil
        }

        guard let payload else {
            return .failure("unsupported panel kind")
        }

        context.resultWindowManager?.show(payload)

        var effects = CompanionTurnEffects()
        effects.panelPayload = payload
        return .success("opened \(payload.title) panel", effects: effects)
    }
}

struct CompanionPresentDocumentCapability: CompanionCapability {
    let name = "present_document"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "present_document",
        "description": """
        Open a local document in Pinky's floating document window or the system default app. \
        Use for PDFs and other files the user should see while you explain them.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Absolute path or ~/ path to the file",
                ],
                "title": [
                    "type": "string",
                    "description": "Optional display title for the document panel",
                ],
                "open_in_system_app": [
                    "type": "boolean",
                    "description": "When true, open in Preview/default app instead of Pinky's panel",
                ],
            ],
            "required": ["file_path"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let rawPath = CompanionCapabilityInput.trimmedString(input["file_path"]),
              let fileURL = PinkyFilePathResolver.resolve(rawPath) else {
            return .failure("could not resolve file path")
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failure("file not found")
        }

        let openInSystemApp = CompanionCapabilityInput.boolValue(input["open_in_system_app"], default: false)
        let title = CompanionCapabilityInput.trimmedString(input["title"]) ?? fileURL.lastPathComponent

        if openInSystemApp {
            guard NSWorkspace.shared.open(fileURL) else {
                return .failure("could not open file in system app")
            }
            return .success("opened \(title) in the default app")
        }

        let source = SkillSourceDocument(
            skillName: fileURL.path,
            title: title,
            fileURL: fileURL,
            pageIndex: 0
        )
        context.documentWindowManager?.show(sources: [source])
        return .success("opened \(title) in the document panel")
    }
}

struct CompanionPresentCopyableContentCapability: CompanionCapability {
    let name = "present_copyable_content"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "present_copyable_content",
        "description": """
        Open a floating window with copyable text the user should copy — code, shell commands, \
        JSON, config snippets, etc. Put the FULL copyable text in body. Do not read long snippets aloud.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Short label for the snippet, e.g. Rename files script",
                ],
                "body": [
                    "type": "string",
                    "description": "The full copyable text to show in the window",
                ],
                "kind": [
                    "type": "string",
                    "enum": ["code", "text", "command", "json"],
                    "description": "code for source code, command for shell/terminal, json for JSON",
                ],
                "language": [
                    "type": "string",
                    "description": "Optional language hint, e.g. python, swift, bash",
                ],
            ],
            "required": ["body"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let body = input["body"] as? String else {
            return .failure("missing body")
        }

        guard let payload = PinkyCopyableContentPayloadBuilder.build(
            title: CompanionCapabilityInput.trimmedString(input["title"]),
            body: body,
            kindRaw: CompanionCapabilityInput.trimmedString(input["kind"]),
            language: CompanionCapabilityInput.trimmedString(input["language"])
        ) else {
            return .failure("copyable content body is empty")
        }

        context.copyableContentWindowManager?.show(payload)
        context.onCopyableContentDelivered?(payload)

        var effects = CompanionTurnEffects()
        effects.copyableContent = payload
        return .success("opened copyable content window for \(payload.title)", effects: effects)
    }
}

// MARK: - Navigate

struct CompanionOpenURLCapability: CompanionCapability {
    let name = "open_url"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "open_url",
        "description": """
        Open a web page in the user's browser. Prefer a new tab when possible. \
        Use after answering live-data questions when showing the page would help.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "Full https URL to open",
                ],
                "browser": [
                    "type": "string",
                    "description": "Optional browser: safari, chrome, arc, or firefox",
                ],
                "new_tab": [
                    "type": "boolean",
                    "description": "Open in a new tab when supported (default true)",
                ],
            ],
            "required": ["url"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let rawURL = CompanionCapabilityInput.trimmedString(input["url"]),
              let url = PinkyURLActionParser.normalizedURL(from: rawURL) else {
            return .failure("invalid url")
        }

        let browser = CompanionCapabilityInput.trimmedString(input["browser"]).map {
            PinkyKnownApplication.normalizedName(from: $0)
        }
        let newTab = CompanionCapabilityInput.boolValue(input["new_tab"], default: true)
        let spoken = PinkyOpenURLActionHandler.openURL(url, browser: browser, newTab: newTab)
        return spoken.contains("couldn't") ? .failure(spoken) : .success(spoken)
    }
}

struct CompanionOpenAppCapability: CompanionCapability {
    let name = "open_app"
    let kind: CompanionCapabilityKind = .act
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "open_app",
        "description": "Launch a macOS application by name.",
        "input_schema": [
            "type": "object",
            "properties": [
                "app_name": [
                    "type": "string",
                    "description": "Application name, e.g. Safari, Spotify, Finder",
                ],
            ],
            "required": ["app_name"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let appName = CompanionCapabilityInput.trimmedString(input["app_name"]) else {
            return .failure("missing app name")
        }

        let normalized = PinkyKnownApplication.normalizedName(from: appName)
        let handler = PinkyOpenAppActionHandler()
        guard let spoken = await handler.execute(.openApp(appName: normalized)) else {
            return .failure("could not open \(appName)")
        }

        return spoken.contains("couldn't") ? .failure(spoken) : .success(spoken)
    }
}

// MARK: - Observe

struct CompanionReadPDFCapability: CompanionCapability {
    let name = "read_pdf"
    let kind: CompanionCapabilityKind = .observe
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "read_pdf",
        "description": """
        Read text from a local PDF file and return extracted content for answering questions. \
        Use before summarizing or quoting a document.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Absolute path or ~/ path to the PDF",
                ],
                "max_pages": [
                    "type": "integer",
                    "description": "Maximum pages to read (default 10)",
                ],
                "max_chars": [
                    "type": "integer",
                    "description": "Maximum characters to return (default 12000)",
                ],
            ],
            "required": ["file_path"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let rawPath = CompanionCapabilityInput.trimmedString(input["file_path"]),
              let fileURL = PinkyFilePathResolver.resolve(rawPath) else {
            return .failure("could not resolve file path")
        }

        guard fileURL.pathExtension.lowercased() == "pdf" else {
            return .failure("file is not a pdf")
        }

        let maxPages = CompanionCapabilityInput.intValue(input["max_pages"]) ?? 10
        let maxChars = CompanionCapabilityInput.intValue(input["max_chars"]) ?? 12_000

        guard let text = PinkyPDFTextExtractor.extractText(from: fileURL, maxPages: maxPages, maxChars: maxChars) else {
            return .failure("could not extract text from pdf")
        }

        return .success(text)
    }
}

struct CompanionReadFileCapability: CompanionCapability {
    let name = "read_file"
    let kind: CompanionCapabilityKind = .observe
    let scopes: Set<CompanionCapabilityScope> = [.agent]

    let toolDefinition: [String: Any] = [
        "name": "read_file",
        "description": """
        Read a local plain-text file and return its contents for answering questions.
        """,
        "input_schema": [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Absolute path or ~/ path to the text file",
                ],
                "max_chars": [
                    "type": "integer",
                    "description": "Maximum characters to return (default 12000)",
                ],
            ],
            "required": ["file_path"],
        ] as [String: Any],
    ]

    func execute(input: [String: Any], context: CompanionCapabilityContext) async -> CompanionCapabilityResult {
        guard let rawPath = CompanionCapabilityInput.trimmedString(input["file_path"]),
              let fileURL = PinkyFilePathResolver.resolve(rawPath) else {
            return .failure("could not resolve file path")
        }

        let maxChars = CompanionCapabilityInput.intValue(input["max_chars"]) ?? 12_000

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data.prefix(maxChars), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return .failure("could not read text file")
        }

        if data.count > maxChars {
            return .success(text + "\n\n[truncated]")
        }

        return .success(text)
    }
}
