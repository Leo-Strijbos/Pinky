//
//  SkillFrontmatter.swift
//  leanring-buddy
//
//  Minimal YAML frontmatter parsing for Agent Skills SKILL.md files.
//

import Foundation

struct SkillFrontmatter: Equatable {
    let name: String
    let description: String
    let license: String?
    let compatibility: String?
    let metadata: [String: String]
}

enum SkillFrontmatterParser {

    static func parse(from markdown: String) -> (frontmatter: SkillFrontmatter, body: String)? {
        let trimmed = markdown.trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix("---") else { return nil }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return nil }

        var endIndex: Int?
        for index in 1..<lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }

        guard let endIndex else { return nil }

        let yamlLines = lines[1..<endIndex]
        let body = lines[(endIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let yaml = parseYAML(Array(yamlLines))

        guard let name = yaml["name"], !name.isEmpty,
              let description = yaml["description"], !description.isEmpty else {
            return nil
        }

        let metadata = parseMetadataBlock(from: Array(yamlLines))

        return (
            SkillFrontmatter(
                name: name,
                description: description,
                license: yaml["license"],
                compatibility: yaml["compatibility"],
                metadata: metadata
            ),
            body
        )
    }

    static func render(
        name: String,
        description: String,
        metadata: [String: String],
        body: String
    ) -> String {
        var lines = [
            "---",
            "name: \(escapeYAMLScalar(name))",
            "description: \(escapeYAMLScalar(description))",
        ]

        if !metadata.isEmpty {
            lines.append("metadata:")
            for key in metadata.keys.sorted() {
                lines.append("  \(key): \(escapeYAMLScalar(metadata[key] ?? ""))")
            }
        }

        lines.append("---")
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func parseYAML(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            if trimmed == "metadata:" {
                index += 1
                while index < lines.count {
                    let metaLine = lines[index]
                    let metaTrimmed = metaLine.trimmingCharacters(in: .whitespaces)
                    if metaTrimmed.contains(":"), metaLine.hasPrefix("  ") {
                        let parts = metaTrimmed.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.count == 2 {
                            result["metadata.\(parts[0].trimmingCharacters(in: .whitespaces))"] =
                                unquoteYAMLScalar(parts[1].trimmingCharacters(in: .whitespaces))
                        }
                        index += 1
                    } else {
                        break
                    }
                }
                continue
            }

            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result[key] = unquoteYAMLScalar(value)
            }

            index += 1
        }

        return result
    }

    private static func parseMetadataBlock(from lines: [String]) -> [String: String] {
        var metadata: [String: String] = [:]
        guard let metadataIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "metadata:" }) else {
            return metadata
        }

        for line in lines[(metadataIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(":"), line.hasPrefix("  ") {
                let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    metadata[parts[0].trimmingCharacters(in: .whitespaces)] =
                        unquoteYAMLScalar(parts[1].trimmingCharacters(in: .whitespaces))
                }
            } else if !trimmed.isEmpty, !line.hasPrefix("  ") {
                break
            }
        }

        return metadata
    }

    private static func escapeYAMLScalar(_ value: String) -> String {
        if value.contains("\"") || value.contains(":") || value.contains("#") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        if value.contains("\n") || value.hasPrefix(" ") || value.hasSuffix(" ") {
            return "\"\(value)\""
        }
        return value
    }

    private static func unquoteYAMLScalar(_ value: String) -> String {
        var text = value
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

enum SkillNameFormatter {
    static func kebabCase(from title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        var collapsed = String(allowed)
        while collapsed.contains("--") {
            collapsed = collapsed.replacingOccurrences(of: "--", with: "-")
        }
        collapsed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if collapsed.isEmpty { return "workflow-\(Int(Date().timeIntervalSince1970))" }
        if collapsed.count > 64 { collapsed = String(collapsed.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return collapsed
    }

    static func uniqueName(base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }
}
