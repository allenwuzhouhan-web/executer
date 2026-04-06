import Foundation

/// Risk tiers for tool execution. Higher tiers get more scrutiny.
enum ToolRiskTier: Int, Comparable {
    case safe = 0       // Read-only, no side effects — silent, no logging
    case normal = 1     // Benign side effects (open app, play music) — silent, audit-logged
    case elevated = 2   // Modifies user files/data — argument validation, logged
    case critical = 3   // System-altering or arbitrary code — dangerous patterns require confirmation

    static func < (lhs: ToolRiskTier, rhs: ToolRiskTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Classifies every registered tool into a risk tier.
enum ToolSafetyClassifier {
    private static let tiers: [String: ToolRiskTier] = [
        // TIER 0: SAFE — read-only, no side effects
        "get_volume": .safe, "get_brightness": .safe, "get_dark_mode": .safe,
        "get_cursor_position": .safe, "get_clipboard_text": .safe, "get_clipboard_image": .safe,
        "get_system_info": .safe, "get_weather": .safe, "get_downloads_path": .safe,
        "get_safari_url": .safe, "get_safari_title": .safe, "get_chrome_url": .safe,
        "get_finder_window_path": .safe,
        "list_running_apps": .safe, "list_windows": .safe, "list_directory": .safe,
        "list_skills": .safe, "list_aliases": .safe, "list_automation_rules": .safe,
        "list_scheduled_tasks": .safe, "list_memories": .safe,
        "music_get_current": .safe,
        "query_calendar_events": .safe, "query_reminders": .safe,
        "search_mail": .safe, "read_email": .safe, "list_mailboxes": .safe,
        "dictionary_lookup": .safe, "thesaurus_lookup": .safe, "spell_check": .safe,
        "file_preview": .safe, "directory_tree": .safe, "get_file_info": .safe,
        "read_file": .safe, "read_pdf_text": .safe,
        "read_safari_page": .safe, "read_safari_html": .safe, "read_chrome_page": .safe,
        "safari_read_elements": .safe, "safari_click": .normal, "safari_type": .normal, "safari_select": .normal,
        "search_file_contents": .safe, "find_files": .safe, "find_files_by_age": .safe,
        "capture_screen": .safe, "capture_window": .safe,
        "capture_screen_to_clipboard": .safe, "capture_area": .safe, "ocr_image": .safe,
        "get_clipboard_history": .safe, "search_clipboard_history": .safe,
        "recall_memories": .safe,
        "semantic_scholar_search": .safe, "get_paper_details": .safe,
        "browser_screenshot": .safe,

        // TIER 0: SAFE — System Bash (read-only scoped shell tools)
        "get_network_info": .safe, "get_disk_usage": .safe,
        "list_processes": .safe, "check_port": .safe,
        "git_status": .safe, "count_lines": .safe,
        "get_env_info": .safe, "ping_host": .safe,
        "whats_using": .safe, "quick_speed_test": .safe,
        "diff_files": .safe, "hash_file": .safe,
        "json_process": .safe, "base64_convert": .safe,
        "text_process": .safe, "sqlite_query": .safe,
        "system_profiler": .safe, "file_watcher": .safe,
        // TIER 1: NORMAL — System Bash (benign side effects)
        "http_request": .normal, "watch_command": .normal,
        "clipboard_pipe": .normal, "docker_command": .normal,
        "image_convert": .normal, "rename_file": .normal,
        // TIER 2: ELEVATED — System Bash (modifies files/system)
        "compress_files": .elevated, "download_file": .elevated,
        "extract_archive": .elevated, "run_script": .elevated,
        "install_package": .elevated, "create_symlink": .elevated,
        "chmod_file": .elevated, "serve_directory": .elevated,
        "git_command": .elevated, "find_replace_in_files": .elevated,
        "cron_manage": .elevated, "ssh_command": .elevated,
        "create_venv": .elevated,
        // TIER 3: CRITICAL — System Bash (process control)
        "kill_process": .critical,

        // TIER 1: NORMAL — benign side effects, routine usage
        "launch_app": .normal, "switch_to_app": .normal, "hide_app": .normal,
        "open_file": .normal, "reveal_in_finder": .normal,
        "open_url": .normal, "search_web": .normal, "search_images": .normal, "open_url_in_safari": .normal, "new_safari_tab": .normal,
        "music_play": .normal, "music_pause": .normal, "music_next": .normal, "music_previous": .normal,
        "music_play_song": .normal, "music_search": .normal, "music_set_volume": .normal,
        "music_toggle_shuffle": .normal,
        "set_volume": .normal, "mute_volume": .normal, "unmute_volume": .normal,
        "set_brightness": .normal, "toggle_dark_mode": .normal, "toggle_night_shift": .normal,
        "toggle_dnd": .normal, "set_dnd_duration": .normal,
        "toggle_wifi": .normal, "toggle_bluetooth": .normal, "connect_bluetooth_device": .normal,
        "move_window": .normal, "resize_window": .normal, "fullscreen_window": .normal,
        "minimize_window": .normal, "tile_window_left": .normal, "tile_window_right": .normal,
        "tile_window_top_left": .normal, "center_window": .normal,
        "tile_windows_side_by_side": .normal, "move_window_to_space": .normal, "arrange_windows": .normal,
        "show_notification": .normal, "speak_text": .normal,
        "set_clipboard_text": .normal,
        "type_text": .normal, "press_key": .normal, "hotkey": .normal, "select_all_text": .normal,
        "move_cursor": .normal, "click": .normal, "click_element": .normal, "click_ref": .normal, "scroll": .normal, "drag": .normal, "explore_ui": .normal,
        "create_reminder": .normal, "create_calendar_event": .normal, "create_note": .normal, "set_timer": .normal, "set_alarm": .normal,
        "list_calendars": .safe, "query_calendar_events": .safe, "update_calendar_event": .normal, "delete_calendar_event": .elevated,
        "list_reminder_lists": .safe, "query_reminders": .safe, "complete_reminder": .normal, "delete_reminder": .elevated,
        "query_notes": .safe, "read_note": .safe, "update_note": .normal, "delete_note": .elevated, "list_note_folders": .safe,
        "open_email": .normal,
        "open_system_preferences_pane": .normal,
        "save_memory": .normal, "forget_memory": .normal,
        "create_alias": .normal, "remove_alias": .normal,
        "lock_screen": .normal, "sleep_display": .normal, "prevent_sleep": .normal,
        "fetch_url_content": .normal,
        "set_weather_key": .normal, "set_semantic_scholar_key": .normal,
        "schedule_task": .normal, "open_terminal": .normal,
        // Subagent tools
        "spawn_subagent": .elevated, "check_agent_status": .safe,
        "wait_for_agent": .safe, "list_background_agents": .safe,
        // Email Briefing
        "send_email_briefing": .elevated, "schedule_email_briefing": .normal,
        "list_email_briefings": .safe, "cancel_email_briefing": .normal,
        "browser_extract": .normal, "browser_session": .normal,
        // Chrome CDP connection
        "browser_connect_chrome": .normal, "browser_disconnect_chrome": .normal,
        "browser_read_elements": .safe, "browser_click_element": .normal, "browser_type_element": .normal,
        "browser_page_state": .safe, "browser_wait_for": .safe, "browser_select_tab": .normal,
        // Browser Intelligence
        "browser_execute_js": .elevated,  // Arbitrary JS execution
        "browser_read_dom": .safe, "browser_get_console": .safe, "browser_inspect_element": .safe,
        "browser_click_element_css": .normal, "browser_type_in_element": .normal,
        "browser_intercept_network": .normal, "browser_navigate": .normal,
        // Vision & Perception
        "perceive_screen": .safe, "perceive_screen_visual": .safe, "find_element": .safe,
        // Fast Input
        "paste_text": .normal,

        // TIER 2: ELEVATED — modifies user files/data
        "write_file": .elevated, "edit_file": .elevated, "append_to_file": .elevated,
        "move_file": .elevated, "copy_file": .elevated, "trash_file": .elevated, "create_folder": .elevated,
        "open_file_with_app": .elevated, "batch_rename_files": .elevated,
        "quit_app": .elevated, "force_quit_app": .elevated, "close_window": .elevated,
        "save_skill": .elevated, "remove_skill": .elevated,
        "create_automation_rule": .elevated, "remove_automation_rule": .elevated, "toggle_automation_rule": .elevated,
        "clear_clipboard_history": .elevated,
        "open_terminal_with_command": .elevated,
        "sleep_system": .elevated,
        "browser_task": .elevated,

        // TIER 2 (MESSAGING): Sends messages on user's behalf
        "send_wechat_message": .elevated, "send_message": .elevated,
        "set_contact_platform": .normal,
        "fetch_wechat_messages": .safe, "read_messages": .safe, "wechat_sent_history": .safe,

        // TIER 3: CRITICAL — system-altering, arbitrary code execution
        "run_shell_command": .critical,
        "shutdown": .critical, "restart": .critical, "log_out": .critical,

        // Skill Verification (read-only status checks + manual override)
        "verify_skill_now": .normal, "list_pending_skills": .safe, "approve_skill": .elevated,

        // Document Operations (read = safe, create = elevated since it runs Python)
        "read_document": .safe, "create_document": .elevated, "setup_python_docs": .elevated,
        "extract_document_style": .safe, "list_document_styles": .safe,
        "get_tool_guide": .safe,
        // Document Training (train = elevated since it runs Python + 3 LLM calls; list/recall = safe)
        "train_document": .elevated, "list_trained_documents": .safe, "recall_trained_knowledge": .safe,
        "create_presentation": .elevated, "extract_ppt_design": .safe,
        "create_word_document": .elevated, "create_spreadsheet": .elevated,
        "create_3d_model": .elevated,
        // RAG (ingest runs Python + reads files = elevated; search/list/info = safe; delete = elevated)
        "rag_ingest": .elevated, "rag_search": .safe,
        "rag_list_collections": .safe, "rag_collection_info": .safe,
        "rag_delete_collection": .elevated,
        // Skill Import (search = safe, import = elevated since it fetches external content)
        "search_github_skills": .normal, "import_skill": .elevated, "list_skill_sources": .safe,
        // Notion (read = safe, write = elevated, setup = normal)
        "notion_setup": .normal,
        "notion_search": .safe, "notion_read_page": .safe, "notion_get_database": .safe,
        "notion_create_page": .elevated, "notion_update_page": .elevated,
        "notion_append_blocks": .elevated, "notion_query_database": .safe,
        "notion_add_to_database": .elevated, "notion_create_database": .elevated,
        "notion_add_comment": .elevated,
        // Media Production (FFmpeg + Audio)
        "ffmpeg_edit_video": .elevated, "create_video": .elevated,
        "ffmpeg_probe": .safe, "create_audio": .elevated,
        "plan_video": .safe, "setup_ffmpeg": .elevated,
        "analyze_youtube_channel": .elevated, "list_video_styles": .safe,
        "quick_video": .elevated, "create_podcast": .elevated,
        "download_youtube": .elevated, "setup_ytdlp": .elevated,
    ]

    /// Returns the risk tier for a tool. Unknown tools default to `.elevated`.
    static func tier(for toolName: String) -> ToolRiskTier {
        tiers[toolName] ?? .elevated
    }
}
