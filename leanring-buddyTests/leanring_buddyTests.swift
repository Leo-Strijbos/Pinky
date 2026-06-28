//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func voiceRouterUsesQuickLocalForGreeting() async throws {
        let decision = CompanionVoiceRouter.resolve(transcript: "hey clicky")
        #expect(decision.route == .quickLocal)
        #expect(decision.cannedResponse == "i'm here.")
    }

    @Test func voiceRouterParsesOpenAppLocally() async throws {
        let decision = CompanionVoiceRouter.resolve(transcript: "please open spotify")
        #expect(decision.route == .appAction)
        #expect(decision.appAction == .openApp(appName: "spotify"))
    }

    @Test func voiceRouterParsesWebOpenLocally() async throws {
        let decision = CompanionVoiceRouter.resolve(transcript: "go to github.com in safari")
        #expect(decision.route == .appAction)
        if case .openURL(let url, let browser, _) = decision.appAction {
            #expect(url.host == "github.com")
            #expect(browser == "safari")
        } else {
            Issue.record("expected openURL app action")
        }
    }

    @Test func voiceRouterDefaultsToAgentForScreenHelp() async throws {
        let decision = CompanionVoiceRouter.resolve(transcript: "what am i looking at on this screen")
        #expect(decision.route == .agent)
    }

    @Test func voiceRouterUsesIntroForMetaQuestion() async throws {
        let decision = CompanionVoiceRouter.resolve(transcript: "who are you")
        #expect(decision.route == .intro)
    }

    @Test func sessionPhrasesDetectAdvanceExitAndCancel() async throws {
        #expect(ClickyVoiceSessionPhrases.isAdvance("next step"))
        #expect(ClickyVoiceSessionPhrases.isAdvance("what do i do next"))
        #expect(ClickyVoiceSessionPhrases.isExit("i've got it from here"))
        #expect(ClickyVoiceSessionPhrases.isExit("skip the rest"))
        #expect(ClickyVoiceSessionPhrases.isCancel("stop walkthrough"))
        #expect(ClickyVoiceSessionPhrases.isRestart("start over"))
        #expect(!ClickyVoiceSessionPhrases.isLikelyStepQuestion("next"))
    }

    @Test func compoundParserBuildsOrderedAppActions() async throws {
        let steps = ClickyVoiceCompoundCommandParser.parse(
            transcript: "open safari then go to github.com"
        )

        #expect(steps?.count == 2)
        #expect(steps?[0] == .appAction(.openApp(appName: "safari"), bridge: nil))

        if case .appAction(.openURL(let url, _, _), _) = steps?[1] {
            #expect(url.host == "github.com")
        } else {
            Issue.record("expected second compound step to open github.com")
        }
    }

    @Test func compoundParserRejectsSingleCommand() async throws {
        let steps = ClickyVoiceCompoundCommandParser.parse(transcript: "open spotify")
        #expect(steps == nil)
    }

    @Test func sessionPlannerParsesRichJSONPlan() async throws {
        let raw = """
        {"title":"make a github repo private","steps":[{"instruction":"open the repo settings","lookFor":"settings tab","doneWhen":"settings page is visible"},{"instruction":"change visibility to private","lookFor":"change visibility","doneWhen":"visibility shows private"}]}
        """
        let parsed = try CompanionSessionPlanner.parseResponse(raw)
        #expect(parsed.title == "make a github repo private")
        #expect(parsed.steps.count == 2)
        #expect(parsed.steps[0].lookFor == "settings tab")
        #expect(parsed.steps[1].doneWhen == "visibility shows private")
    }

    @Test func agentGeneratedPlanBuildsGuideSteps() async throws {
        let plan = CompanionSessionPlanBuilder.agentGeneratedPlan(
            title: "make repo private",
            steps: [
                CompanionSessionPlanner.ParsedStep(
                    instruction: "open settings",
                    lookFor: "settings tab",
                    doneWhen: "settings page is open",
                    substeps: ["click the settings tab"]
                ),
                CompanionSessionPlanner.ParsedStep(
                    instruction: "set visibility to private",
                    lookFor: nil,
                    doneWhen: nil,
                    substeps: nil
                ),
            ]
        )

        #expect(plan?.steps.count == 2)
        #expect(plan?.policy.advanceMode == .hybrid)
        if case .guide(let step) = plan?.steps.first {
            #expect(step.instruction == "open settings")
            #expect(step.completion == .visionCheck(description: "settings page is open"))
            #expect(step.substeps == ["click the settings tab"])
            #expect(step.pointing == .ifOnScreen)
        } else {
            Issue.record("expected guide step")
        }

        if case .guide(let secondStep) = plan?.steps.last {
            #expect(secondStep.completion == .manual)
        }
    }

    @Test func knowledgePolicyQuestionIsNotStepByStepIntent() async throws {
        #expect(!ClickyProcedureQuery.isStepByStepIntent("what's our new employee onboarding policy?"))
        #expect(!ClickyProcedureQuery.isStepByStepIntent("tell me about the vacation policy"))
        #expect(ClickyKnowledgeRetriever.isKnowledgeDocumentQuery("what's our new employee onboarding policy?"))
    }

    @Test func proceduralKnowledgeQuestionIsStillStepByStepIntent() async throws {
        #expect(ClickyProcedureQuery.isStepByStepIntent("walk me through our onboarding policy"))
        #expect(ClickyProcedureQuery.isStepByStepIntent("how do i follow the vacation policy"))
    }

    @Test func walkthroughRoutingSkipsScriptRunFollowUps() async throws {
        #expect(!ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "how do I use this/run this? Where should I run it?",
            context: .empty
        ))
        #expect(!ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "okay, I've copied it. how do I run it now?",
            context: .empty
        ))
        #expect(!ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "how do I run this python script in terminal?",
            context: .empty
        ))
    }

    @Test func walkthroughRoutingSkipsFollowUpAfterRecentCode() async throws {
        let context = CompanionWalkthroughRoutingContext(
            recentExchanges: [
                (
                    user: "can you give me a python script to rename files?",
                    assistant: "here's a short script you can copy."
                ),
            ],
            recentCopyableKind: .code
        )

        #expect(!ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "how do I use this? Where should I run it?",
            context: context
        ))
        #expect(!ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "okay, what's next?",
            context: context
        ))
    }

    @Test func walkthroughRoutingStillStartsGreenfieldHowTo() async throws {
        #expect(ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "show me how to view my battery health",
            context: .empty
        ))
        #expect(ClickyProcedureQuery.shouldStartWalkthroughPlanning(
            transcript: "how do i make a repo private",
            context: .empty
        ))
    }

    @MainActor
    @Test func sessionManagerSkipsPlanForScriptRunFollowUp() async throws {
        let manager = CompanionSessionManager()
        let monitor = CompanionSessionCompletionMonitor(
            claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5")
        )
        let context = CompanionWalkthroughRoutingContext(
            recentExchanges: [
                (
                    user: "write a python script to rename files",
                    assistant: "copy this script into a file."
                ),
            ],
            recentCopyableKind: .code
        )
        let outcome = await manager.process(
            transcript: "okay, I've copied it. how do I run it now?",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor,
            routingContext: context
        )
        #expect(outcome == nil)
    }

    @MainActor
    @Test func sessionManagerRequestsPlanForGeneralHowTo() async throws {
        let manager = CompanionSessionManager()
        let monitor = CompanionSessionCompletionMonitor(claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5"))
        let outcome = await manager.process(
            transcript: "how do i make a repo private",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )
        #expect(outcome == .needsPlan(transcript: "how do i make a repo private"))
    }

    @MainActor
    @Test func sessionManagerSkipsPlanForKnowledgePolicyQuestion() async throws {
        let manager = CompanionSessionManager()
        let monitor = CompanionSessionCompletionMonitor(claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5"))
        let outcome = await manager.process(
            transcript: "what's our new employee onboarding policy?",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )
        #expect(outcome == nil)
    }

    @Test func sessionContinuityEndsUnrelatedRequests() async throws {
        let plan = CompanionSessionPlan(
            title: "make repo private",
            source: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open the settings tab on the repo page",
                    lookFor: "settings",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "change visibility to private",
                    lookFor: nil,
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )
        let session = CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: nil,
            stepReadyAt: Date(),
            hasShownAdvanceHint: false
        )

        #expect(!ClickyVoiceSessionContinuity.continuesWalkthrough("what's the weather", session: session))

        let manager = CompanionSessionManager()
        manager.debugSetActiveSession(session)
        let monitor = CompanionSessionCompletionMonitor(claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5"))
        let outcome = await manager.process(
            transcript: "what's the weather",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )
        if case .exitAndContinue(let remaining) = outcome {
            #expect(remaining.contains("weather"))
            #expect(manager.activeSession == nil)
        } else {
            Issue.record("expected walkthrough to end for unrelated request")
        }
    }

    @Test func sessionContinuityKeepsShortFollowUps() async throws {
        let plan = CompanionSessionPlan(
            title: "automate gmail to spreadsheet",
            source: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open zapier",
                    lookFor: "zapier",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "create a zap",
                    lookFor: "create",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )
        let session = CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: nil,
            stepReadyAt: Date(),
            hasShownAdvanceHint: false
        )

        #expect(
            ClickyVoiceSessionContinuity.continuesWalkthrough("okay, and now?", session: session)
        )
    }

    @MainActor
    @Test func sessionManagerTreatsAndNowAsCurrentStepQuestion() async throws {
        let plan = CompanionSessionPlan(
            title: "automate gmail to spreadsheet",
            source: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open zapier",
                    lookFor: "zapier",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "create a zap",
                    lookFor: "create",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )

        let manager = CompanionSessionManager()
        manager.debugSetActiveSession(CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: nil,
            stepReadyAt: Date(),
            hasShownAdvanceHint: false
        ))

        let monitor = CompanionSessionCompletionMonitor(
            claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5")
        )
        let outcome = await manager.process(
            transcript: "okay, and now?",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )

        if case .agentTurn(let question, let session) = outcome {
            #expect(question.contains("and now"))
            #expect(session.currentIndex == 0)
            #expect(manager.activeSession != nil)
        } else {
            Issue.record("expected current-step agent turn for okay and now")
        }
    }

    @Test func sessionContinuityKeepsStepFollowUps() async throws {
        let plan = CompanionSessionPlan(
            title: "make darwin gp private",
            source: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open the darwin gp repository on github",
                    lookFor: "darwin gp",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "open settings",
                    lookFor: "settings",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )
        let session = CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: nil,
            stepReadyAt: Date(),
            hasShownAdvanceHint: false
        )

        #expect(
            ClickyVoiceSessionContinuity.continuesWalkthrough(
                "okay i've clicked on darwin gp what do i do next",
                session: session
            )
        )
    }

    @MainActor
    @Test func sessionManagerHandlesUserDoneHandoff() async throws {
        let plan = CompanionSessionPlan(
            title: "Export PDF",
            source: .agentGenerated,
            policy: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open the file menu",
                    lookFor: "File",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "choose export as pdf",
                    lookFor: "Export",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )

        let manager = CompanionSessionManager()
        manager.debugSetActiveSession(CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: PlaybookScreenContextCapture.captureCurrentContext(),
            stepReadyAt: Date(),
            hasShownAdvanceHint: true
        ))

        let monitor = CompanionSessionCompletionMonitor(claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5"))
        let outcome = await manager.process(
            transcript: "i'm good",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )

        if case .ended(let spoken) = outcome {
            #expect(spoken.contains("step back"))
            #expect(manager.activeSession == nil)
        } else {
            Issue.record("expected userDone handoff")
        }
    }

    @Test func milestoneCompilerGroupsSharedScreenSteps() async throws {
        let steps = [
            PlaybookStep(
                id: "s1",
                playbookID: "wf-test",
                index: 0,
                title: "Open menu",
                instruction: "open the file menu",
                contextApp: "Preview",
                contextURLPattern: nil,
                contextWindowPattern: "Document",
                lookFor: "File",
                doneWhen: nil,
                thumbnailFilename: nil,
                capturedAt: Date()
            ),
            PlaybookStep(
                id: "s2",
                playbookID: "wf-test",
                index: 1,
                title: "Choose export",
                instruction: "choose export as pdf",
                contextApp: "Preview",
                contextURLPattern: nil,
                contextWindowPattern: "Document",
                lookFor: "Export",
                doneWhen: nil,
                thumbnailFilename: nil,
                capturedAt: Date()
            ),
            PlaybookStep(
                id: "s3",
                playbookID: "wf-test",
                index: 2,
                title: "Confirm export",
                instruction: "click save",
                contextApp: "Preview",
                contextURLPattern: nil,
                contextWindowPattern: "Export",
                lookFor: "Save",
                doneWhen: nil,
                thumbnailFilename: nil,
                capturedAt: Date()
            ),
        ]

        let groups = PlaybookMilestoneCompiler.groups(from: steps)
        #expect(groups.count == 2)
        #expect(groups[0].steps.count == 2)
        #expect(groups[1].steps.count == 1)

        let guide = PlaybookSessionAdapter.guideStep(for: groups[0], orderedSteps: steps)
        #expect(guide.substeps?.count == 2)
        #expect(guide.playbookStepIDs == ["s1", "s2"])
        #expect(guide.completion == .playbookStep(stepID: "s3"))
    }

    @Test func screenContextDeltaDetectsNavigation() async throws {
        let before = PlaybookScreenContext(app: "Safari", url: "https://github.com/a/b", windowTitle: "Repo")
        let after = PlaybookScreenContext(app: "Safari", url: "https://github.com/a/b/settings", windowTitle: "Settings")
        #expect(CompanionScreenContextDelta.hasMeaningfulChange(from: before, to: after))
        #expect(!CompanionScreenContextDelta.hasMeaningfulChange(from: before, to: before))
    }

    @Test func sessionPlannerParsesMilestoneSubsteps() async throws {
        let raw = """
        {"title":"export a pdf","steps":[{"instruction":"open export options","substeps":["open the file menu","choose export"],"lookFor":"file menu","doneWhen":"export panel is visible"},{"instruction":"save the pdf","lookFor":"save","doneWhen":"save dialog is open"}]}
        """
        let parsed = try CompanionSessionPlanner.parseResponse(raw)
        #expect(parsed.steps.count == 2)
        #expect(parsed.steps[0].substeps?.count == 2)
    }

    @MainActor
    @Test func sessionManagerHandlesAdvanceAndCancel() async throws {
        let workflowSteps = [
            PlaybookStep(
                id: "s1",
                playbookID: "wf-test",
                index: 0,
                title: "Open menu",
                instruction: "open the file menu",
                contextApp: "Preview",
                contextURLPattern: nil,
                contextWindowPattern: nil,
                lookFor: "Open menu",
                doneWhen: nil,
                thumbnailFilename: "s1.jpg",
                capturedAt: Date()
            ),
            PlaybookStep(
                id: "s2",
                playbookID: "wf-test",
                index: 1,
                title: "Choose export",
                instruction: "choose export as pdf",
                contextApp: "Preview",
                contextURLPattern: nil,
                contextWindowPattern: nil,
                lookFor: "Choose export",
                doneWhen: nil,
                thumbnailFilename: "s2.jpg",
                capturedAt: Date()
            ),
        ]
        let guide = PlaybookSessionAdapter.guideStep(
            for: PlaybookMilestoneGroup(steps: [workflowSteps[0]]),
            orderedSteps: workflowSteps
        )
        let plan = CompanionSessionPlan(
            title: "Export PDF",
            source: .storedProcedure,
            steps: [
                .guide(guide),
                .guide(CompanionGuideStep(
                    instruction: "choose export as pdf",
                    lookFor: "Choose export",
                    completion: .manual,
                    pointing: .ifOnScreen,
                    playbookStepIDs: ["s2"]
                )),
            ],
            playbookID: "wf-test",
            playbookSteps: workflowSteps
        )

        let manager = CompanionSessionManager()
        manager.debugSetActiveSession(CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: PlaybookScreenContextCapture.captureCurrentContext(),
            stepReadyAt: Date(),
            hasShownAdvanceHint: true
        ))

        let monitor = CompanionSessionCompletionMonitor(claudeAPI: ClaudeAPI(proxyURL: "https://example.com", model: "claude-haiku-4-5"))
        let advance = await manager.process(
            transcript: "next",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )
        if case .executeGuideStep(let session) = advance {
            #expect(session.currentIndex == 1)
        } else {
            Issue.record("expected guide step execution for step 2")
        }

        let cancel = await manager.process(
            transcript: "stop",
            workflowManager: PlaybookManager(),
            completionMonitor: monitor
        )
        if case .ended(let spoken) = cancel {
            #expect(spoken.contains("stopping"))
            #expect(manager.activeSession == nil)
        } else {
            Issue.record("expected session cancel")
        }
    }

    @MainActor
    @Test func sessionManagerEntersShadowModeAfterAutoAdvances() async throws {
        let plan = CompanionSessionPlan(
            title: "Export PDF",
            source: .agentGenerated,
            policy: .agentGenerated,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "open the file menu",
                    lookFor: "File",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "choose export as pdf",
                    lookFor: "Export",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "click save",
                    lookFor: "Save",
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )

        let session = CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: PlaybookScreenContext(app: "Preview", url: nil, windowTitle: "Doc"),
            stepReadyAt: Date().addingTimeInterval(-10),
            hasShownAdvanceHint: true,
            consecutiveAutoAdvances: 1
        )

        let manager = CompanionSessionManager()
        let outcome = manager.debugMoveToNextStep(from: session, wasAutomatic: true)
        if case .autoAdvanced(_, let advancedSession) = outcome {
            #expect(advancedSession.coachingMode == .shadowing)
            #expect(advancedSession.currentIndex == 1)
        } else {
            Issue.record("expected silent shadow auto-advance")
        }
    }

    @Test func promptFormatterUsesMinimalAdvanceHintByDefault() async throws {
        let plan = CompanionSessionPlan(
            title: "test",
            source: .agentGenerated,
            policy: .default,
            steps: [
                .guide(CompanionGuideStep(
                    instruction: "click settings",
                    lookFor: nil,
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
                .guide(CompanionGuideStep(
                    instruction: "choose private",
                    lookFor: nil,
                    completion: .manual,
                    pointing: .ifOnScreen
                )),
            ]
        )
        let session = CompanionActiveSession(
            plan: plan,
            currentIndex: 0,
            awaitingAdvance: true,
            stepContextSnapshot: nil,
            stepReadyAt: Date(),
            hasShownAdvanceHint: false
        )

        #expect(CompanionSessionPromptFormatter.advanceHint(for: session) == nil)
    }

    @Test func exitPhraseExtractsTrailingCommand() async throws {
        let command = ClickyVoiceSessionPhrases.commandAfterWalkthroughExit(
            in: "Okay, I'm all right, thank you. I've got it from here. Can you please open up Spotify and play Back in Black?"
        )
        #expect(command.contains("open up spotify"))
        #expect(command.contains("play back in black"))

        let steps = ClickyVoiceCompoundCommandParser.parse(transcript: command)
        #expect(steps?.count == 2)
    }

    @Test func capabilityRegistryScopesAgentAndGuideTools() async throws {
        let registry = CompanionCapabilityRegistry.standard
        let agentNames = Set(registry.toolDefinitions(for: .agent).compactMap { $0["name"] as? String })
        let guideNames = Set(registry.toolDefinitions(for: .guideStep).compactMap { $0["name"] as? String })

        #expect(agentNames.contains("open_url"))
        #expect(agentNames.contains("read_pdf"))
        #expect(agentNames.contains("present_copyable_content"))
        #expect(guideNames == ["point_at_element"])
    }

    @Test func capabilityRegistryExecutesPointAtElement() async throws {
        let registry = CompanionCapabilityRegistry.standard
        let result = await registry.execute(
            name: "point_at_element",
            input: ["x": 120, "y": 240, "label": "Settings"],
            context: .empty
        )

        #expect(result.success)
        #expect(result.effects.pointTarget?.label == "Settings")
    }

    @Test func filePathResolverExpandsTildePaths() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let resolved = ClickyFilePathResolver.resolve("~/")
        #expect(resolved?.standardizedFileURL.path == home.standardizedFileURL.path)
    }

    @Test func readFileCapabilityReadsPlainText() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-capability-test.txt")
        try "hello from clicky".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let registry = CompanionCapabilityRegistry.standard
        let result = await registry.execute(
            name: "read_file",
            input: ["file_path": tempURL.path],
            context: .empty
        )

        #expect(result.success)
        #expect(result.toolResultContent.contains("hello from clicky"))
    }

    @Test func actionSpeechSummarizesOpenURLAndPoint() async throws {
        let actions = [
            CompanionExecutedAction(
                capabilityName: "open_url",
                resultContent: "opening weather.com in a new Safari tab.",
                pointLabel: nil
            ),
            CompanionExecutedAction(
                capabilityName: "point_at_element",
                resultContent: "pointed at Settings",
                pointLabel: "Settings"
            ),
        ]

        let summary = CompanionAgentActionSpeech.spokenSummary(for: actions)
        #expect(summary?.contains("opening weather.com") == true)
        #expect(summary?.contains("Settings") == true)
    }

    @Test func actionSpeechIgnoresSyntheticFallback() async throws {
        #expect(CompanionAgentActionSpeech.isSyntheticFallback("I couldn't find a clear answer from the web."))

        let resolved = CompanionAgentActionSpeech.resolveSpokenText(
            modelText: "I couldn't find a clear answer from the web.",
            executedActions: [
                CompanionExecutedAction(
                    capabilityName: "open_url",
                    resultContent: "opening weather.com in a new Safari tab.",
                    pointLabel: nil
                ),
            ],
            effects: CompanionTurnEffects()
        )

        #expect(resolved.contains("opening weather.com"))
        #expect(!resolved.lowercased().contains("couldn't find"))
    }

    @Test func copyableContentCapabilityOpensWindowPayload() async throws {
        let payload = ClickyCopyableContentPayloadBuilder.build(
            title: "Hello script",
            body: "print('hi')",
            kindRaw: "code",
            language: "python"
        )
        #expect(payload?.kind == .code)
        #expect(payload?.language == "python")

        let registry = CompanionCapabilityRegistry.standard
        let result = await registry.execute(
            name: "present_copyable_content",
            input: [
                "title": "Hello script",
                "body": "print('hi')",
                "kind": "code",
                "language": "python",
            ],
            context: .empty
        )

        #expect(result.success)
        #expect(result.effects.copyableContent?.body == "print('hi')")
    }

    @Test func actionSpeechForCopyableContent() async throws {
        let summary = CompanionAgentActionSpeech.spokenSummary(for: [
            CompanionExecutedAction(
                capabilityName: "present_copyable_content",
                resultContent: "opened copyable content window for SQL query",
                pointLabel: nil
            ),
        ])
        #expect(summary?.contains("new window") == true)
    }

    @Test func taskClassifierDetectsCrossAppAutomation() async throws {
        let hints = CompanionSessionTaskClassifier.hints(
            for: "how do i automatically add incoming gmail emails to a google spreadsheet"
        )
        #expect(hints.archetype == .crossAppAutomation)
        #expect(hints.suggestWebSearch)
        #expect(hints.preferStrongerModel)
    }

    @Test func taskClassifierLeavesInAppSettingsAlone() async throws {
        let hints = CompanionSessionTaskClassifier.hints(
            for: "how do i make a github repo private"
        )
        #expect(hints.archetype == .inAppSettings)
        #expect(!hints.suggestWebSearch)
    }

    @Test func sessionPlannerParsesReadyTopology() async throws {
        let raw = """
        {"status":"ready","title":"Gmail to Sheets","taskType":"cross_app_automation","recommendedApproach":"Use Zapier","assumptions":["Zapier"],"orderedPhases":["Open Zapier","Set Gmail trigger","Set Sheets action","Test the Zap"],"orchestrator":"Zapier","avoidFirst":["Gmail inbox"]}
        """
        let parsed = try CompanionSessionPlanner.parseTopologyResponse(raw)
        #expect(parsed.status == .ready)
        #expect(parsed.orderedPhases.count == 4)
        #expect(parsed.orchestrator == "Zapier")
    }

    @Test func sessionPlannerParsesClarificationTopology() async throws {
        let raw = """
        {"status":"needs_clarification","title":"Gmail to spreadsheet","taskType":"cross_app_automation","recommendedApproach":"Zapier is the easiest option.","partialOrderedPhases":["Open automation tool","Configure Gmail trigger","Configure spreadsheet action"],"questions":[{"question":"Are you using Zapier or Make?","defaultAssumption":"Zapier"}]}
        """
        let parsed = try CompanionSessionPlanner.parseTopologyResponse(raw)
        #expect(parsed.status == .needsClarification)
        #expect(parsed.questions.count == 1)
        #expect(parsed.questions[0].defaultAssumption == "Zapier")
    }

    @Test func planningBriefFormatterBuildsMultiQuestionPrompt() async throws {
        let spoken = CompanionSessionPlanningBriefFormatter.spokenPrompt(
            questions: [
                CompanionSessionPlanningQuestion(
                    question: "Are you using Zapier or Make?",
                    defaultAssumption: "Zapier"
                ),
                CompanionSessionPlanningQuestion(
                    question: "Should new emails add a row to Google Sheets or Airtable?",
                    defaultAssumption: "Google Sheets"
                ),
            ],
            recommendedApproach: "Zapier is usually the fastest way to connect Gmail and Google Sheets."
        )
        #expect(spoken.contains("Zapier is usually the fastest"))
        #expect(spoken.contains("Are you using Zapier or Make?"))
        #expect(spoken.contains("go ahead"))
    }

    @Test func planningBriefFormatterDetectsProceedWithDefaults() async throws {
        #expect(CompanionSessionPlanningBriefFormatter.isProceedWithDefaults("go ahead"))
        #expect(CompanionSessionPlanningBriefFormatter.isProceedWithDefaults("sounds good"))
        #expect(!CompanionSessionPlanningBriefFormatter.isProceedWithDefaults("i use make"))
    }

    @Test func planningBriefFormatterDetectsRetryAfterFailure() async throws {
        #expect(CompanionSessionPlanningBriefFormatter.shouldRetryFailedPlanning("yeah, please do that"))
        #expect(CompanionSessionPlanningBriefFormatter.shouldRetryFailedPlanning("okay, please show me what to do"))
    }

    @Test func planningScreenContextAppendixIncludesPlatformAndIrrelevanceHint() async throws {
        let appendix = CompanionSessionPlanningContext.screenContextAppendix(
            for: PlaybookScreenContext(
                app: "Safari",
                url: "https://example.com",
                windowTitle: "Example Page"
            )
        )
        #expect(appendix.contains("platform: macOS"))
        #expect(appendix.contains("frontmost app: Safari"))
        #expect(appendix.contains("browser url: https://example.com"))
        #expect(appendix.contains("ignore it when unrelated"))
    }

    @Test func sessionPlannerBuildsFallbackPlanFromTopology() async throws {
        let topology = CompanionSessionTopology(
            title: "Gmail to Sheets",
            taskType: "cross_app_automation",
            recommendedApproach: "Use Zapier",
            assumptions: ["Zapier"],
            orderedPhases: [
                "Open Zapier and create a new Zap",
                "Set Gmail as the trigger",
                "Set Google Sheets as the action",
            ],
            orchestrator: "Zapier",
            avoidFirst: ["Gmail inbox"],
            notes: nil
        )

        let fallback = CompanionSessionPlanner.planFromTopology(topology)
        #expect(fallback?.steps.count == 3)
        #expect(fallback?.steps[0].instruction.contains("Zapier") == true)
    }

}
