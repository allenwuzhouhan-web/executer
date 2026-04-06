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
  - `blender_engine.py` — Creates 3D models from JSON spec with embedded bpy code. Runs inside Blender headless (`blender -b -P`). Handles scene setup, materials, validation (manifold/normals/loose geometry), and export (GLB/OBJ/FBX/STL).

### 3D Model Creation
- **Swift orchestrator** (`Executer/Executors/BlenderExecutor.swift`):
  - `CreateBlenderModelTool` — writes JSON spec to temp file, runs `blender_engine.py` via headless Blender
  - `BlenderExecutor.findBlender()` — searches known paths for Blender executable, caches result
  - `BlenderExecutor.runBlender()` — subprocess execution with pipe deadlock prevention and 120s timeout
  - Requires Blender installed on the system (not a pip dependency — bpy is built into Blender's Python)
- **Hybrid approach**: LLM generates `bpy_code` (geometry creation), engine handles scene setup, material helpers, validation, and export
- **Validation**: mesh.validate(), manifold edges, consistent normals, no loose vertices/edges, no zero-area faces, material assignment, export file integrity (GLB magic bytes)
- **Security**: `bpy_code` is checked for dangerous imports (os, subprocess, sys, etc.) before execution

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

### Media Production (FFmpeg + Audio)
- **Swift orchestrator** (`Executer/Executors/FFmpegExecutor.swift`):
  - `FFmpegExecutor` enum — helper methods: `findFFmpeg()`, `findFFprobe()` (cached path discovery), `ensureResource()`, `runEngine()` (spec → Python → FFmpeg subprocess with timeout), `probe()` (direct ffprobe call)
  - 8 tools: `setup_ffmpeg`, `ffmpeg_probe`, `ffmpeg_edit_video`, `create_video`, `create_audio`, `plan_video`, `quick_video`, `create_podcast`
  - `QuickVideoTool` — one-shot video creation: topic + narration → auto-searches images in parallel → generates scenes → TTS → subtitles → auto-opens result
  - `CreatePodcastTool` — one-shot podcast creation: narration text → TTS → optional background music with ducking → auto-opens result
  - `FFmpegEditVideoTool` — operations pipeline (trim, merge, overlay_text, overlay_image, add_audio, speed, resize, crop, rotate, extract_audio, add_subtitles, fade, color_adjust, stabilize). `pipeline: true` chains ops sequentially.
  - `CreateVideoTool` — scene-based composer (image/title_card/video/color_card scenes, Ken Burns animations, xfade transitions, integrated TTS via macOS `say`, background music with ducking, auto-subtitles)
  - `CreateAudioTool` — track-based audio (tts/file/silence/tone tracks, layer or sequence mixing, sidechaincompress ducking)
  - `PlanVideoTool` — pure Swift template generator for video types (explainer, tutorial, montage, podcast, vlog, promo, slideshow)
- **Python engines** (`Executer/Resources/`):
  - `ffmpeg_engine.py` — mode "edit" (operations pipeline) and mode "create" (scene composer). Zero pip deps.
  - `audio_engine.py` — TTS via macOS `say -o`, tone gen via FFmpeg lavfi, mixing with sidechaincompress. Zero pip deps.
- **Video Style Learning** (`Executer/Learning/VideoStyleLearner.swift`):
  - `AnalyzeYouTubeChannelTool` — yt-dlp download → ffprobe metadata → scene detection → audio analysis → style synthesis → saves `video_style_<name>.json`
  - `ListVideoStylesTool` — reads video_styles/ directory
  - Style profiles stored at `~/Library/Application Support/Executer/video_styles/`
- **Discovery pattern**: Same as BlenderExecutor — search `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `which` fallback, cache in static var
- **Adding new edit operations**: Add `build_<name>` function in `ffmpeg_engine.py`, register in `EDIT_BUILDERS` dict
- **Auto-search**: `create_video` scenes support `search_query` instead of `source` — auto-searches for images via `ImageSearchService`
- **Auto-open**: `create_video`, `ffmpeg_edit_video`, `create_audio`, `quick_video`, `create_podcast`, `download_youtube` all auto-open results by default

### YouTube / Media Download (yt-dlp)
- **Swift executor** (`Executer/Executors/YouTubeExecutor.swift`):
  - `YouTubeExecutor` enum — `findYTDLP()` (cached path discovery), `runYTDLP()` (subprocess with timeout)
  - `DownloadYouTubeTool` — download videos/audio from YouTube, TikTok, Instagram, Vimeo, etc. Format selection (best/720p/480p/audio_only/mp3), subtitle embedding, playlist support
  - `SetupYTDLPTool` — check/install yt-dlp via Homebrew
- Requires yt-dlp CLI installed on the system (not a pip dependency from within the app)
- Uses FFmpeg for format merging when available

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

### Notion Integration
- `Executer/Executors/NotionService.swift` — API client (`NotionAPI` actor), Keychain token storage (`NotionKeyStore`), markdown↔blocks conversion (`NotionBlockBuilder`, `NotionBlockReader`), property formatting (`NotionPropertyFormatter`).
- `Executer/Executors/NotionExecutor.swift` — 11 tools: `notion_setup`, `notion_search`, `notion_read_page`, `notion_create_page`, `notion_update_page`, `notion_append_blocks`, `notion_query_database`, `notion_get_database`, `notion_add_to_database`, `notion_create_database`, `notion_add_comment`.
- Calls Notion REST API directly via `PinnedURLSession` (no external MCP server process needed).
- Token stored in Keychain via `NotionKeyStore`. User sets up via `notion_setup` tool with their integration token from https://www.notion.so/profile/integrations.
- Markdown → Notion blocks supports: headings, bullets, numbered lists, code blocks, quotes, tables, to-dos, dividers, images, inline bold/italic/strikethrough/code/links.
- Database operations auto-detect property types from schema — user provides simple key-value pairs, the tools build proper Notion property objects.

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
