//
//  ClickyLiveDataQuery.swift
//  leanring-buddy
//
//  Detects questions that need fresh web search — weather, stocks, news, etc.
//

import Foundation

enum ClickyLiveDataQuery {

    static func requiresFreshWebSearch(_ query: String) -> Bool {
        let normalized = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let liveDataPhrases = [
            "weather",
            "forecast",
            "temperature",
            "rain",
            "rainy",
            "sunny",
            "snow",
            "humidity",
            "stock price",
            "share price",
            "trading at",
            "market cap",
            "exchange rate",
            "news about",
            "latest on",
            "sports score",
            "who won",
            "election results",
            "opening hours",
            "what time is",
        ]

        return liveDataPhrases.contains { normalized.contains($0) }
    }

    static func forcedSearchUserPrompt(for transcript: String) -> String {
        """
        The user needs current, live information from the web. You MUST call web_search before answering. Do not answer from memory, training data, or guess.

        User question: \(transcript)
        """
    }

    static let liveDataSystemPromptAppendix = """
    critical — live information:
    for weather, forecasts, stock prices, exchange rates, sports scores, breaking news, and any time-sensitive facts, you MUST use web_search before answering.
    never guess temperatures, conditions, prices, or scores from memory.
    if web_search returns nothing useful, say you couldn't find a reliable current answer — do not invent numbers.
    if this live-information question is unrelated to what's on screen or to an earlier task you were helping with, ignore the screenshot and earlier topic. answer only the latest question.
    after answering live-data questions, you may use open_url to open a relevant page in a new tab when that would help the user.
    """
}
