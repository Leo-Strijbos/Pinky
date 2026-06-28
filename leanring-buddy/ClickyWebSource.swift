//
//  ClickyWebSource.swift
//  leanring-buddy
//
//  Citation metadata from Claude web search responses.
//

import Foundation

struct ClickyWebSource: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let url: URL

    init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}
