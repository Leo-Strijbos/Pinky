//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "claude-sonnet-4-6") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a text-only request to Claude with streaming. Use for cheap routing
    /// paths that don't need a screenshot (Haiku gate, general questions).
    func sendTextStreaming(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        model: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let requestModel = model ?? self.model

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            let trimmedUser = userPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAssistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { continue }
            messages.append(["role": "user", "content": trimmedUser])
            messages.append(["role": "assistant", "content": trimmedAssistant])
        }
        messages.append(["role": "user", "content": userPrompt])

        let body: [String: Any] = [
            "model": requestModel,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("🌐 Claude text streaming request: model=\(requestModel)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Cheap Haiku call for voice route classification. Returns raw JSON text.
    func sendVoiceRouteClassification(
        systemPrompt: String,
        userPrompt: String,
        model: String = "claude-haiku-4-5"
    ) async throws -> String {
        let parsedResponse = try await sendMessagesRequest(
            systemPrompt: systemPrompt,
            messages: [["role": "user", "content": userPrompt]],
            model: model,
            tools: nil,
            maxTokens: 256
        )
        return parsedResponse.text
    }

    /// Text-only structured JSON call for session planning phases.
    func sendStructuredJSON(
        systemPrompt: String,
        userPrompt: String,
        model: String? = nil,
        maxTokens: Int = 1024
    ) async throws -> String {
        let parsedResponse = try await sendMessagesRequest(
            systemPrompt: systemPrompt,
            messages: [["role": "user", "content": userPrompt]],
            model: model ?? self.model,
            tools: nil,
            maxTokens: maxTokens
        )
        return parsedResponse.text
    }

    /// One-shot web search brief for session planning topology.
    func sendPlanningResearchBrief(
        systemPrompt: String,
        userPrompt: String,
        model: String? = nil
    ) async throws -> String {
        let requestModel = model ?? self.model
        var messages: [[String: Any]] = [["role": "user", "content": userPrompt]]
        let tools: [[String: Any]] = [[
            "type": "web_search_20250305",
            "name": "web_search",
            "max_uses": 1,
        ]]

        while true {
            let parsedResponse = try await sendMessagesRequest(
                systemPrompt: systemPrompt,
                messages: messages,
                model: requestModel,
                tools: tools,
                maxTokens: 512
            )

            if parsedResponse.stopReason == "pause_turn" {
                messages.append([
                    "role": "assistant",
                    "content": parsedResponse.assistantContent,
                ])
                continue
            }

            let text = parsedResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return ""
            }
            return text
        }
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        model: String? = nil,
        maxTokens: Int = 512
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let requestModel = model ?? self.model

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            let trimmedUser = userPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAssistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { continue }
            messages.append(["role": "user", "content": trimmedUser])
            messages.append(["role": "assistant", "content": trimmedAssistant])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": requestModel,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, httpResponse) = try await performDataRequestWithRetry(request: request)

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    /// Vision agent turn with web search and client-side capabilities.
    func sendVisionAgentTurn(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        model: String? = nil,
        includeWebSearch: Bool = true,
        capabilityRegistry: CompanionCapabilityRegistry,
        capabilityScope: CompanionCapabilityScope,
        capabilityContext: CompanionCapabilityContext
    ) async throws -> CompanionAgentTurnResult {
        let requestModel = model ?? self.model
        var messages = buildVisionMessages(
            conversationHistory: conversationHistory,
            images: images,
            userPrompt: userPrompt
        )

        let payloadMB = estimateVisionPayloadMegabytes(for: messages)
        print("🌐 Claude agent turn: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        return try await sendMessagesAgentTurn(
            systemPrompt: systemPrompt,
            messages: &messages,
            model: requestModel,
            includeWebSearch: includeWebSearch,
            capabilityRegistry: capabilityRegistry,
            capabilityScope: capabilityScope,
            capabilityContext: capabilityContext
        )
    }

    private func sendMessagesAgentTurn(
        systemPrompt: String,
        messages: inout [[String: Any]],
        model: String,
        includeWebSearch: Bool,
        capabilityRegistry: CompanionCapabilityRegistry,
        capabilityScope: CompanionCapabilityScope,
        capabilityContext: CompanionCapabilityContext,
        maxTokens: Int = 2048
    ) async throws -> CompanionAgentTurnResult {
        var tools = capabilityRegistry.toolDefinitions(for: capabilityScope)
        if includeWebSearch {
            tools.insert(
                [
                    "type": "web_search_20250305",
                    "name": "web_search",
                    "max_uses": 3,
                ],
                at: 0
            )
        }

        var accumulatedSources: [PinkyWebSource] = []
        var seenSourceURLs = Set<String>()
        var usedWebSearch = false
        var turnEffects = CompanionTurnEffects()
        var accumulatedActions: [CompanionExecutedAction] = []

        while true {
            let parsedResponse = try await sendMessagesRequest(
                systemPrompt: systemPrompt,
                messages: messages,
                model: model,
                tools: tools,
                maxTokens: maxTokens
            )

            usedWebSearch = usedWebSearch || parsedResponse.usedWebSearch
            mergeSources(parsedResponse.sources, into: &accumulatedSources, seenURLs: &seenSourceURLs)

            if parsedResponse.stopReason == "pause_turn" {
                messages.append([
                    "role": "assistant",
                    "content": parsedResponse.assistantContent,
                ])
                continue
            }

            if parsedResponse.stopReason == "tool_use" {
                let capabilityToolUses = capabilityRegistry.clientToolUseBlocks(
                    from: parsedResponse.assistantContent,
                    scope: capabilityScope
                )
                let modelText = parsedResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasSpeakableText = !modelText.isEmpty
                    && !CompanionAgentActionSpeech.isSyntheticFallback(modelText)

                if !capabilityToolUses.isEmpty {
                    let execution = await capabilityRegistry.executeToolUses(
                        capabilityToolUses,
                        context: capabilityContext
                    )
                    turnEffects.merge(execution.effects)
                    accumulatedActions.append(contentsOf: execution.executedActions)

                    if hasSpeakableText {
                        print(
                            "🌐 Agent turn complete: usedWebSearch=\(usedWebSearch), point=\(turnEffects.pointTarget != nil), panel=\(turnEffects.panelPayload != nil)"
                        )
                        return CompanionAgentTurnResult(
                            spokenText: modelText,
                            sources: accumulatedSources,
                            usedWebSearch: usedWebSearch,
                            pointTarget: turnEffects.pointTarget,
                            panelPayload: turnEffects.panelPayload
                        )
                    }

                    let observeOnly = !execution.executedActions.isEmpty
                        && execution.executedActions.allSatisfy {
                            CompanionAgentActionSpeech.isObserveCapability($0.capabilityName)
                        }

                    if observeOnly, !execution.toolResults.isEmpty {
                        messages.append([
                            "role": "assistant",
                            "content": parsedResponse.assistantContent,
                        ])
                        messages.append([
                            "role": "user",
                            "content": execution.toolResults,
                        ])
                        continue
                    }

                    if let actionSpeech = CompanionAgentActionSpeech.spokenSummary(for: accumulatedActions) {
                        print(
                            "🌐 Agent turn complete: action speech=\"\(actionSpeech)\", point=\(turnEffects.pointTarget != nil), panel=\(turnEffects.panelPayload != nil)"
                        )
                        return CompanionAgentTurnResult(
                            spokenText: actionSpeech,
                            sources: accumulatedSources,
                            usedWebSearch: usedWebSearch,
                            pointTarget: turnEffects.pointTarget,
                            panelPayload: turnEffects.panelPayload
                        )
                    }

                    guard !execution.toolResults.isEmpty else {
                        print("⚠️ Agent turn: capability tools produced no results")
                        return CompanionAgentTurnResult(
                            spokenText: "",
                            sources: accumulatedSources,
                            usedWebSearch: usedWebSearch,
                            pointTarget: turnEffects.pointTarget,
                            panelPayload: turnEffects.panelPayload
                        )
                    }

                    messages.append([
                        "role": "assistant",
                        "content": parsedResponse.assistantContent,
                    ])
                    messages.append([
                        "role": "user",
                        "content": execution.toolResults,
                    ])
                    continue
                }
            }

            print(
                "🌐 Agent turn complete: usedWebSearch=\(usedWebSearch), point=\(turnEffects.pointTarget != nil), panel=\(turnEffects.panelPayload != nil), stop=\(parsedResponse.stopReason)"
            )

            let spokenText = CompanionAgentActionSpeech.resolveSpokenText(
                modelText: parsedResponse.text,
                executedActions: accumulatedActions,
                effects: turnEffects
            )

            if spokenText.isEmpty, usedWebSearch, accumulatedActions.isEmpty, turnEffects.pointTarget == nil,
               turnEffects.panelPayload == nil {
                return CompanionAgentTurnResult(
                    spokenText: "i couldn't find a clear answer.",
                    sources: accumulatedSources,
                    usedWebSearch: usedWebSearch,
                    pointTarget: nil,
                    panelPayload: nil
                )
            }

            return CompanionAgentTurnResult(
                spokenText: spokenText,
                sources: accumulatedSources,
                usedWebSearch: usedWebSearch,
                pointTarget: turnEffects.pointTarget,
                panelPayload: turnEffects.panelPayload
            )
        }
    }

    private struct ParsedClaudeMessageResponse {
        let text: String
        let sources: [PinkyWebSource]
        let stopReason: String
        let assistantContent: [[String: Any]]
        let usedWebSearch: Bool
    }

    private func mergeSources(
        _ newSources: [PinkyWebSource],
        into accumulatedSources: inout [PinkyWebSource],
        seenURLs: inout Set<String>
    ) {
        for source in newSources {
            let normalizedURL = source.url.absoluteString
            guard !seenURLs.contains(normalizedURL) else { continue }
            seenURLs.insert(normalizedURL)
            accumulatedSources.append(source)
        }
    }

    private func buildVisionMessages(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            let trimmedUser = userPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAssistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUser.isEmpty, !trimmedAssistant.isEmpty else { continue }
            messages.append(["role": "user", "content": trimmedUser])
            messages.append(["role": "assistant", "content": trimmedAssistant])
        }

        messages.append([
            "role": "user",
            "content": buildVisionContentBlocks(images: images, userPrompt: userPrompt),
        ])

        return messages
    }

    private func buildVisionContentBlocks(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var contentBlocks: [[String: Any]] = []

        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString(),
                ],
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label,
            ])
        }

        contentBlocks.append([
            "type": "text",
            "text": userPrompt,
        ])

        return contentBlocks
    }

    private func estimateVisionPayloadMegabytes(for messages: [[String: Any]]) -> Double {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: messages) else {
            return 0
        }
        return Double(jsonData.count) / 1_048_576.0
    }

    private func sendMessagesRequest(
        systemPrompt: String,
        messages: [[String: Any]],
        model: String,
        tools: [[String: Any]]? = nil,
        maxTokens: Int
    ) async throws -> ParsedClaudeMessageResponse {
        var request = makeAPIRequest()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages,
        ]

        if let tools {
            body["tools"] = tools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("🌐 Claude messages request: model=\(model), tools=\(tools?.count ?? 0)")

        let (data, httpResponse) = try await performDataRequestWithRetry(request: request)

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(responseString)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]
            )
        }

        return parseClaudeMessageResponse(json)
    }

    private func parseClaudeMessageResponse(_ json: [String: Any]) -> ParsedClaudeMessageResponse {
        let stopReason = json["stop_reason"] as? String ?? "end_turn"
        let contentBlocks = json["content"] as? [[String: Any]] ?? []

        var textParts: [String] = []
        var sources: [PinkyWebSource] = []
        var seenSourceURLs = Set<String>()
        var usedWebSearch = false

        for block in contentBlocks {
            let blockType = block["type"] as? String ?? ""

            if blockType == "server_tool_use",
               (block["name"] as? String) == "web_search" {
                usedWebSearch = true
            }

            if blockType == "web_search_tool_use" || blockType == "web_search_tool_result" {
                usedWebSearch = true
            }

            if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                textParts.append(text)
            }

            if let citations = block["citations"] as? [[String: Any]] {
                usedWebSearch = true
                for citation in citations {
                    appendSource(from: citation, to: &sources, seenURLs: &seenSourceURLs)
                }
            }

            if blockType == "web_search_tool_result",
               let searchResults = block["content"] as? [[String: Any]] {
                usedWebSearch = true
                for result in searchResults {
                    appendSource(from: result, to: &sources, seenURLs: &seenSourceURLs)
                }
            }
        }

        let combinedText = textParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasClientToolUse = contentBlocks.contains { ($0["type"] as? String) == "tool_use" }

        let resolvedText: String
        if !combinedText.isEmpty {
            resolvedText = combinedText
        } else if hasClientToolUse {
            resolvedText = ""
        } else if usedWebSearch {
            resolvedText = "I couldn't find a clear answer from the web."
        } else {
            resolvedText = ""
        }

        return ParsedClaudeMessageResponse(
            text: resolvedText,
            sources: sources,
            stopReason: stopReason,
            assistantContent: contentBlocks,
            usedWebSearch: usedWebSearch
        )
    }

    private func appendSource(
        from dictionary: [String: Any],
        to sources: inout [PinkyWebSource],
        seenURLs: inout Set<String>
    ) {
        guard let urlString = dictionary["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }

        let normalizedURL = url.absoluteString
        guard !seenURLs.contains(normalizedURL) else { return }
        seenURLs.insert(normalizedURL)

        let title = (dictionary["title"] as? String)
            ?? url.host
            ?? normalizedURL
        sources.append(PinkyWebSource(title: title, url: url))
    }

    private static let maxRetryAttempts = 3

    private func isRetriableStatusCode(_ code: Int) -> Bool {
        code == 429 || code == 502 || code == 503 || code == 504
    }

    private func sleepBeforeRetry(attempt: Int) async {
        let seconds = min(attempt, 3)
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    private func performDataRequestWithRetry(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastResponse: HTTPURLResponse?
        var lastData = Data()

        for attempt in 1...Self.maxRetryAttempts {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                )
            }

            if (200...299).contains(httpResponse.statusCode) {
                return (data, httpResponse)
            }

            lastResponse = httpResponse
            lastData = data

            if isRetriableStatusCode(httpResponse.statusCode), attempt < Self.maxRetryAttempts {
                print("🌐 Claude request retry \(attempt)/\(Self.maxRetryAttempts) after HTTP \(httpResponse.statusCode)")
                await sleepBeforeRetry(attempt: attempt)
                continue
            }

            break
        }

        let statusCode = lastResponse?.statusCode ?? -1
        let responseString = String(data: lastData, encoding: .utf8) ?? "Unknown error"
        throw NSError(
            domain: "ClaudeAPI",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "API Error (\(statusCode)): \(responseString)"]
        )
    }

    private func performStreamingRequestWithRetry(request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var lastResponse: HTTPURLResponse?

        for attempt in 1...Self.maxRetryAttempts {
            let (byteStream, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                )
            }

            if (200...299).contains(httpResponse.statusCode) {
                return (byteStream, httpResponse)
            }

            lastResponse = httpResponse

            if isRetriableStatusCode(httpResponse.statusCode), attempt < Self.maxRetryAttempts {
                print("🌐 Claude streaming retry \(attempt)/\(Self.maxRetryAttempts) after HTTP \(httpResponse.statusCode)")
                await sleepBeforeRetry(attempt: attempt)
                continue
            }

            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        throw NSError(
            domain: "ClaudeAPI",
            code: lastResponse?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: "API Error: request failed after retries"]
        )
    }
}
