//
//  ClickyWebResultIntent.swift
//  leanring-buddy
//
//  Builds embeddable web URLs for stock charts and places maps.
//

import Foundation

enum ClickyWebResultKind: String, Equatable {
    case stockChart
    case placesMap
}

struct ClickyWebResultPayload: Equatable {
    let kind: ClickyWebResultKind
    let title: String
    let url: URL
}

enum ClickyWebResultPayloadBuilder {

    static func stockChart(ticker rawTicker: String) -> ClickyWebResultPayload? {
        let ticker = rawTicker
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "$", with: "")

        guard !ticker.isEmpty,
              ticker.count <= 5,
              ticker.allSatisfy({ $0.isLetter }) else {
            return nil
        }

        let title = "\(ticker) chart"
        guard let url = URL(string: "https://finance.yahoo.com/quote/\(ticker)/chart") else {
            return nil
        }

        return ClickyWebResultPayload(kind: .stockChart, title: title, url: url)
    }

    static func placesMap(searchQuery rawSearchQuery: String) -> ClickyWebResultPayload? {
        let searchQuery = rawSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return nil }

        var urlComponents = URLComponents(string: "https://www.google.com/maps/search/")!
        urlComponents.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: searchQuery),
        ]

        guard let url = urlComponents.url else { return nil }

        let title = searchQuery.prefix(60).description
        return ClickyWebResultPayload(kind: .placesMap, title: title, url: url)
    }
}
