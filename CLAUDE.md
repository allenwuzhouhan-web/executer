# Executer — Project Guide

## What is this?
A macOS native Swift app that acts as an AI desktop assistant. It uses LLMs (Claude, OpenAI, Ollama) to execute tasks on the user's Mac — controlling apps, creating documents, browsing the web, managing files, and more.

## Build & Run
```bash
python3 generate_project.py   # Regenerate Xcode project (auto-discovers Swift + resource files)
xcodebuild -scheme Executer -configuration Debug -destination 'platform=macOS' build
```
- `generate_project.py` auto-discovers all `.swift` files in `Executer/` and `.py`/`.json` files in `Executer/Resources/`
- No need to manually add files to the Xcode project — just run the generator

## Architecture

### Core Loop
- `Executer/LLM/AgentLoop.swift` — Main agent loop: LLM generates tool calls, tools execute, results feed back
- `Executer/LLM/LLMProvider.swift` — System prompt construction, model routing (Claude/OpenAI/Ollama)
- `Executer/LLM/ToolRegistry.swift` — Central tool registry with category-based filtering and intent classification
- `Executer/LLM/ToolDefinition.swift` — Protocol all tools conform to

### Document Creation (PPT/Word/Excel)
The document pipeline uses **Python engines invoked as subprocesses** from Swift:

- **Swift orchestrators** (`Executer/Executors/PPTExecutor.swift`):
  - `CreatePresentationTool` — writes JSON spec to temp file, runs `ppt_engine.py`, passes `--design` for learned style
  - `CreateWordDocumentTool` — same pattern with `docx_engine.py`
  - `CreateSpreadsheetTool` — same pattern with `xlsx_engine.py`
  - `PPTExecutor.ensureResource()` — copies Python scripts from app bundle to `~/Library/Application Support/Executer/`
  - `PPTExecutor.runPython()` — subprocess execution (reads pipes BEFORE waitUntilExit to avoid deadlock)

- **Python engines** (`Executer/Resources/`):
  - `ppt_engine.py` — Builds .pptx from JSON spec + `design_language.json`. 15 layout types. Uses `python-pptx`.
  - `docx_engine.py` — Builds .docx from JSON spec. Uses `python-docx`.
  - `xlsx_engine.py` — Builds .xlsx from JSON spec. Uses `openpyxl`.
  - `ppt_design_extractor.py` — Extracts design language from existing .pptx files (colors, fonts, spatial layout, visual effects, design philosophy)
  - `image_utils.py` — Shared image download/validation (URL→local file, retry, WebP→PNG conversion, caching)

- **PPT Engine Design System** (`ppt_engine.py`):
  - `DesignLanguage` class loads `design_language.json` and applies: semantic colors, fonts, text hierarchy, spatial layout patterns, global spacing, visual effects flags, design philosophy
  - Tint/shade system auto-derives `color_accent_light`, `color_accent_dark`, `color_bg_subtle` from accent
  - Visual effects (shadows, gradients, rounded corners) default to OFF — only enabled when source deck uses them
  - `design_philosophy` analysis: content_density, whitespace_style, layout_complexity, color_restraint, effects_usage
  - All derived colors MUST be in DEFAULTS dict as fallback (or crashes without design_language.json)

- **Design Learning Pipeline** (`Executer/Learning/`):
  - `DocumentTrainer.swift` — Orchestrates training: extracts content, runs 8-stage LLM analysis, saves `design_language.json`
  - `TrainerAgentPipeline.swift` — 8-stage LLM analysis (content → structure → design → principles → placement → optimization → factcheck → final)
  - `DocumentStudyProfile.swift` — Stores training results. `promptSection()` injects design rules + philosophy into LLM context.
  - Design language files: `~/Library/Application Support/Executer/design_language_<safename>.json` (per-file) and `design_language.json` (global)
  - **File naming**: safe name = `URL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")` + `.json`

### Image Search
- `Executer/Executors/ImageSearchExecutor.swift` — `search_images` tool with multi-provider fallback (DuckDuckGo → Unsplash)
- Thread-safe cache with `DispatchQueue`, 30-minute TTL
- Results filtered by resolution (min 400x300), orientation preference, junk domain blocking

### Security
- `Executer/Security/ToolSafetyClassifier.swift` — Per-tool safety classification
- `Executer/Security/IntegrityChecker.swift` — App integrity verification

## Key Patterns

### Adding a New Tool
1. Create a struct conforming to `ToolDefinition` in `Executer/Executors/`
2. Register in `ToolRegistry.swift` `allTools` array
3. Add category mapping in `toolCategories` dict
4. Add safety classification in `ToolSafetyClassifier.swift`
5. Run `python3 generate_project.py` to pick up the new file

### Adding a New PPT Layout
1. Add `build_<name>(self, content, slide_num)` method to `SlideBuilder` in `ppt_engine.py`
2. Register in the `builders` dict inside `build_slide()` dispatcher
3. Document in `CreatePresentationTool.description` in `PPTExecutor.swift`

### Python Resource Deployment
All Python scripts are copied from the app bundle to `~/Library/Application Support/Executer/` on first use via `PPTExecutor.ensureResource()`. When modifying Python scripts during development, delete the App Support copies to force re-copy.

### PPT Spec Advisor (Intelligence Layer)
`ppt_engine.py` has an `advise_and_fix_spec()` function that runs BEFORE rendering. It auto-fixes:
- Dense slides (7+ bullets) → auto-split into multiple slides of 4 bullets each
- Long titles (80+ chars) → truncated with ellipsis
- Long bullets (120+ chars) → truncated
- Missing speaker notes → auto-generated from content
- Monotonous layout rhythm → warns when 4+ identical layouts in a row
Warnings are returned in the JSON result as `advisor_notes` and surfaced to the LLM so it can learn.

### MCP (Model Context Protocol) Client
- `Executer/LLM/MCPClient.swift` — Actor-based JSON-RPC 2.0 client over stdio. Connects to MCP servers as child processes.
- `Executer/LLM/MCPToolWrapper.swift` — Wraps MCP-discovered tools as `ToolDefinition` (prefixed `mcp_servername_toolname`).
- `Executer/LLM/MCPServerManager.swift` — Manages multiple server connections. Config at `~/Library/Application Support/Executer/mcp_servers.json`.
- MCP tools auto-register in `ToolRegistry.init()` and default to Tier 2 (elevated) safety.
- Servers connect on app launch in background (`AppDelegate`).

### Smart Tool Approval
- `SecurityGateway.swift` now has `assessToolRisk()` — sends Tier 2-3 tool calls to a fast LLM for risk classification (SAFE/CAUTION/DANGEROUS).
- Session-scoped cache prevents redundant LLM calls for identical tool+args.
- DANGEROUS tools trigger user confirmation dialog.

### Auto-Skill Creation
- `AgentLoop.swift` records workflows with 5+ successful tool calls as auto-skills in `auto_skills.json`.
- Max 50 auto-skills retained, deduped by description.

### Frozen Memory Snapshot
- `LLMProvider.swift` caches the memory section on first use per session.
- Preserves LLM prefix cache efficiency — system prompt stays stable across turns.
- Call `refreshMemoryCache()` to force refresh on new session.

## Critical Invariants
- **Pipe deadlock prevention**: `PPTExecutor.runPython()` MUST read stdout/stderr pipes BEFORE calling `process.waitUntilExit()`. Reversing this deadlocks when output exceeds ~64KB.
- **DEFAULTS completeness**: Every color key used in layout builders (`color_bg_subtle`, `color_accent_light`, etc.) MUST have a fallback value in the `DEFAULTS` dict in `ppt_engine.py`. Missing keys → `hex_to_rgb(None)` → crash.
- **Design language file extension**: Both `DocumentTrainer` and `PPTExecutor` must use `.json` extension in the filename. The trainer writes to `design_language_<name>.json` and the executor looks for the same path.
- **Visual effects default OFF**: Shadows, gradients, and rounded corners are disabled by default. Only enabled when `visual_effects.has_shadows` (etc.) is True in the extracted design language. The user's style is minimal — do not add decorative effects unless the source deck has them.
