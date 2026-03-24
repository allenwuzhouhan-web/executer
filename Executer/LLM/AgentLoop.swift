import Foundation

/// Runs the multi-turn LLM agent loop: send messages, execute tool calls, repeat.
/// Extracted from AppState to isolate LLM execution concerns.
class AgentLoop {

    /// Execute a command through the multi-turn agent loop.
    /// Returns a cancellable Task.
    func execute(
        fullCommand: String,
        resolvedCommand: String,
        previousMessages: [ChatMessage],
        onStateChange: @MainActor @escaping (InputBarState) -> Void,
        onComplete: @MainActor @escaping (_ displayMessage: String, _ filteredText: String, _ messages: [ChatMessage]) -> Void,
        onError: @MainActor @escaping (String) -> Void
    ) -> Task<Void, Never> {
        return Task.detached {
            do {
                let manager = LLMServiceManager.shared
                let registry = ToolRegistry.shared
                let context = SystemContext.current()
                let tools = registry.toolDefinitions()

                let isDeepResearch = fullCommand.hasPrefix("[deep research]")
                let maxIterations = 15
                let maxTokens = isDeepResearch ? 8192 : 2048

                // Build message chain — reuse previous for follow-ups
                var messages: [ChatMessage]
                if !previousMessages.isEmpty {
                    messages = previousMessages
                    messages.append(ChatMessage(role: "user", content: fullCommand))
                } else {
                    messages = [
                        ChatMessage(role: "system", content: manager.fullSystemPrompt(context: context, query: fullCommand)),
                        ChatMessage(role: "user", content: fullCommand)
                    ]
                }

                var finalText = "Done."

                // Multi-turn agent loop: LLM can call tools, see results, then call more tools
                for iteration in 0..<maxIterations {
                    // Check for cancellation before each iteration
                    if Task.isCancelled {
                        print("[Agent] Task cancelled at iteration \(iteration + 1)")
                        return
                    }

                    print("[Agent] Iteration \(iteration + 1)/\(maxIterations) — sending \(messages.count) messages")

                    let response = try await manager.currentService.sendChatRequest(
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )

                    guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else {
                        // No tool calls — LLM is done, use its text as the final response
                        finalText = response.text ?? "Done."
                        print("[Agent] No tool calls — final response: \(finalText)")
                        break
                    }

                    // Append the assistant's message (contains tool_calls)
                    messages.append(response.rawMessage)

                    // Execute each tool call and append results
                    for call in toolCalls {
                        if Task.isCancelled {
                            print("[Agent] Task cancelled during tool execution")
                            return
                        }

                        let friendlyNames: [String: String] = [
                            "launch_app": "Opening app", "quit_app": "Closing app",
                            "click": "Clicking", "click_element": "Clicking",
                            "type_text": "Typing", "press_key": "Pressing key",
                            "hotkey": "Shortcut", "scroll": "Scrolling",
                            "move_cursor": "Moving cursor", "drag": "Dragging",
                            "capture_screen": "Looking", "ocr_image": "Reading screen",
                            "open_url": "Opening URL", "open_url_in_safari": "Opening Safari",
                            "search_web": "Searching", "dictionary_lookup": "Looking up",
                            "music_play_song": "Playing", "music_pause": "Pausing",
                        ]
                        let displayName = friendlyNames[call.function.name] ?? call.function.name
                        print("[Agent] Tool call: \(call.function.name)(\(call.function.arguments))")
                        await MainActor.run {
                            onStateChange(.executing(toolName: displayName, step: iteration + 1, total: maxIterations))
                        }

                        let result: String
                        do {
                            result = try await registry.execute(
                                toolName: call.function.name,
                                arguments: call.function.arguments
                            )
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }
                        print("[Agent] Result: \(result)")

                        // Brief delay after UI interaction tools so the OS processes each action
                        if call.function.name == "launch_app" {
                            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s for app launch
                        } else if ["click", "click_element", "type_text", "press_key", "hotkey", "scroll", "move_cursor"].contains(call.function.name) {
                            try await Task.sleep(nanoseconds: 200_000_000) // 200ms for UI actions
                        }

                        messages.append(ChatMessage(
                            role: "tool",
                            content: result,
                            tool_call_id: call.id
                        ))
                    }
                    // Loop continues — LLM sees tool results and can call more tools or finish
                }

                // Apply personality post-filter before display
                let filteredText = PersonalityEngine.shared.postFilterResponse(finalText)

                // Show result inline — no file dumping
                let displayMessage = filteredText

                // Save to handoff (use unfiltered text for full content)
                HandoffService.shared.saveHandoff(
                    command: resolvedCommand,
                    response: finalText,
                    appContext: context.frontmostApp
                )

                await MainActor.run {
                    onComplete(displayMessage, filteredText, messages)
                }

                // No auto-dismiss — user closes with Escape / hotkey / notch click
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    onError(error.localizedDescription)
                }
            }
        }
    }
}
