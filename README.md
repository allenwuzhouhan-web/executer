# Executer

A native macOS system control assistant powered by LLMs. Lives in your notch, controls your entire Mac through natural language.

## What it does

Type a command in the notch bar (or speak it), and Executer carries it out — launching apps, moving files, controlling music, researching topics, sending messages, automating workflows, and more. It chains 100+ tools together to handle complex multi-step tasks autonomously.

## Features

- **Notch-native UI** — click the notch or press `Cmd+Shift+Space` to summon the command bar
- **100+ system tools** — file management, app control, cursor/keyboard automation, screen capture + OCR, clipboard history, shell commands, and more
- **Multi-provider LLM** — supports Claude, DeepSeek, Gemini, Kimi, and MiniMax with one-click switching
- **Voice control** — speak commands with always-listening mode and custom wake word
- **Research agent** — deep research with Semantic Scholar academic papers + web sources, all with citations
- **Automation rules** — "when X happens, do Y" natural language automation with system event triggers
- **Sub-agent orchestration** — parallel execution, planning, and streaming for complex tasks
- **WeChat + iMessage** — send and read messages across platforms
- **Smart routing** — classifies queries to skip the LLM for instant responses when possible
- **Thought continuity** — remembers context across sessions via memory and thought recall
- **Skills system** — learns and saves multi-step workflows for reuse
- **News briefings** — morning news cards with configurable categories

## Setup

1. Open the project with Xcode (`generate_project.py` generates `Executer.xcodeproj` via [XcodeGen](https://github.com/yonaskolb/XcodeGen))
2. Build and run
3. Grant **Accessibility** and **Input Monitoring** permissions when prompted
4. Open Settings and add your API keys:
   - **LLM provider key** (required) — Claude, DeepSeek, Gemini, Kimi, or MiniMax
   - **Weather API key** (optional) — from [weatherapi.com](https://www.weatherapi.com)
   - **NewsAPI key** (optional) — from [newsapi.org](https://newsapi.org)
   - **Semantic Scholar key** (optional) — from [semanticscholar.org](https://www.semanticscholar.org/product/api)

All keys are stored in the macOS Keychain. No keys are hardcoded or stored in files.

## Architecture

```
Executer/
  App/            — AppDelegate, AppState, system context, health checks
  LLM/            — Multi-provider LLM layer, agent loop, tool registry, sub-agents
  Executors/      — 24 executor modules (file, terminal, cursor, music, weather, news...)
  UI/             — Notch input bar, result bubbles, settings, animations
  Automation/     — Event bus, rule engine, natural language rule parser
  Memory/         — Persistent memory across sessions
  Skills/         — Learned multi-step workflows
  Voice/          — Voice input with wake word detection
  WeChat/         — WeChat message automation
  Storage/        — Clipboard history, aliases, task scheduler, keychain
  Security/       — Path validation, sandboxing
  ThoughtContinuity/ — Cross-session context recall
```

## Requirements

- macOS 14.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## License

MIT
