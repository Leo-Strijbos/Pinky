//
//  PinkyCopyableContentModels.swift
//  leanring-buddy
//
//  Payload for generated copyable text shown in a floating panel.
//

import Foundation

struct PinkyCopyableContentPayload: Equatable {
    enum Kind: String, Equatable {
        case code
        case text
        case command
        case json

        var displayName: String {
            switch self {
            case .code: return "Code"
            case .text: return "Text"
            case .command: return "Command"
            case .json: return "JSON"
            }
        }

        var systemImageName: String {
            switch self {
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .text: return "doc.text"
            case .command: return "terminal"
            case .json: return "curlybraces"
            }
        }

        static func parse(_ raw: String?) -> Kind {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "code": return .code
            case "command", "shell", "bash": return .command
            case "json": return .json
            default: return .text
            }
        }
    }

    let title: String
    let body: String
    let language: String?
    let kind: Kind

    init(
        title: String,
        body: String,
        language: String? = nil,
        kind: Kind = .text
    ) {
        self.title = title
        self.body = body
        if let language {
            let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
            self.language = trimmedLanguage.isEmpty ? nil : trimmedLanguage
        } else {
            self.language = nil
        }
        self.kind = kind
    }
}

enum PinkyCopyableContentPayloadBuilder {
    static func build(
        title: String?,
        body: String,
        kindRaw: String?,
        language: String?
    ) -> PinkyCopyableContentPayload? {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return nil }

        let resolvedTitle = title
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? PinkyCopyableContentPayload.Kind.parse(kindRaw).displayName

        return PinkyCopyableContentPayload(
            title: resolvedTitle,
            body: body,
            language: language,
            kind: .parse(kindRaw)
        )
    }
}
