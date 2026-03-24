import Foundation

/// Humor mode transforms boring status messages into chaotic, funny alternatives.
/// Your Mac becomes your unhinged best friend.
class HumorMode {
    static let shared = HumorMode()
    private init() {}

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "humor_mode_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "humor_mode_enabled") }
    }

    // MARK: - Processing (Thinking) Messages

    private let thinkingMessages = [
        "Consulting the ancient scrolls...",
        "Asking my mom for advice...",
        "Googling it (don't tell anyone)...",
        "Pretending to think really hard...",
        "Loading braincells...",
        "Hold on, my hamster is powering the wheel...",
        "Sacrificing a CPU cycle to the silicon gods...",
        "Let me put on my thinking cap... ok it's on...",
        "Running advanced calculations (2+2=?)...",
        "Downloading more RAM real quick...",
        "Warming up my neurons...",
        "Spinning up the motivation engine...",
        "Channeling my inner Einstein...",
        "Doing the thing... you know... THE thing...",
        "Negotiating with the cloud...",
        "Bribing the API gods...",
        "Entering the matrix...",
        "Hacking the mainframe (not really)...",
        "Summoning digital spirits...",
        "Microwaving some hot takes...",
    ]

    // MARK: - Tool Execution Messages

    private let toolMessages: [String: [String]] = [
        // App control
        "launch_app": [
            "Waking up your app from its nap...",
            "Summoning the app from the shadow realm...",
            "Dragging the app out of bed...",
            "Politely asking the app to show up to work...",
            "Bribing the app with CPU cycles...",
        ],
        "quit_app": [
            "Showing the app the exit door...",
            "Telling the app it's fired...",
            "App has been voted off the island...",
            "Sending the app to the shadow realm...",
            "The app has left the chat...",
        ],
        "force_quit_app": [
            "Yeeting the app into oblivion...",
            "Performing emergency app surgery...",
            "DROP TABLE app; --",
            "The app chose violence, and so did I...",
        ],

        // Volume
        "set_volume": [
            "Adjusting the noise machine...",
            "Twisting the volume knob aggressively...",
            "Making your speakers go brrr...",
            "Calibrating audio vibes...",
            "Telling your speakers how loud to be...",
        ],
        "mute_volume": [
            "Shhhh... silencing everything...",
            "Activating stealth mode...",
            "Making your Mac go real quiet...",
            "Entering ninja mode...",
        ],
        "unmute_volume": [
            "Unleashing the sound waves...",
            "Breaking the silence...",
            "Sound has been freed from its prison...",
        ],

        // Music
        "music_play": [
            "Dropping the beat...",
            "DJ Executer in the house...",
            "Pressing play with dramatic flair...",
            "Unleashing the tunes...",
        ],
        "music_pause": [
            "Hitting the brakes on the vibes...",
            "Putting the music in timeout...",
            "The DJ needs a bathroom break...",
            "Freezing the beat mid-drop...",
        ],
        "music_next": [
            "This song is mid, skipping...",
            "Next! I'm not feeling this one...",
            "Fast-forwarding through the cringe...",
        ],
        "music_previous": [
            "Wait that last song was a banger...",
            "Going back to replay that masterpiece...",
            "Rewinding the vibes...",
        ],
        "music_play_song": [
            "Searching Apple's entire music vault...",
            "Finding your banger in 90 million songs...",
            "Hunting for the perfect track...",
        ],

        // Brightness
        "set_brightness": [
            "Adjusting the sun simulator...",
            "Making your eyeballs happy...",
            "Calibrating screen tan intensity...",
            "Photon manipulation in progress...",
        ],

        // Dark mode
        "toggle_dark_mode": [
            "Switching to the dark side...",
            "Adjusting the vibe lighting...",
            "Your Mac is having a goth phase...",
            "Installing drip...",
        ],

        // Screenshot
        "capture_screen": [
            "Say cheese! Taking the pic...",
            "Screenshotting your digital life...",
            "Capturing this moment for eternity...",
            "Committing your screen to memory...",
        ],

        // Lock/Sleep
        "lock_screen": [
            "Deploying anti-sibling defense system...",
            "Activating Fort Knox mode...",
            "Nobody gets in. Nobody.",
            "Engaging privacy shields...",
        ],
        "sleep_display": [
            "Tucking your Mac into bed...",
            "Goodnight sweet display...",
            "Screen's going night-night...",
        ],

        // Files
        "find_files": [
            "Rummaging through your digital closet...",
            "Playing hide and seek with your files...",
            "Searching every nook and cranny...",
        ],
        "trash_file": [
            "Yoinking that file to the shadow realm...",
            "This file has been eliminated...",
            "Bye bye! Gone forever (jk it's in Trash)...",
        ],
        "move_file": [
            "Relocating this file's entire life...",
            "File is packing its bags and moving...",
        ],

        // Shell
        "run_shell_command": [
            "Hacking the mainframe (legally)...",
            "Executing forbidden terminal arts...",
            "Doing nerdy computer stuff...",
            "Speaking to the machine in its native tongue...",
        ],

        // Web
        "fetch_url_content": [
            "Stalking the internet for answers...",
            "Crawling the web like a spider...",
            "Reading the internet so you don't have to...",
            "Downloading knowledge...",
        ],
        "search_web": [
            "Surfing the information superhighway...",
            "Let me Google that for you (with style)...",
            "Asking the internet hive mind...",
        ],
        "open_url": [
            "Opening the portal to the internet...",
            "Launching you into cyberspace...",
        ],

        // DND
        "toggle_do_not_disturb": [
            "Activating 'leave me alone' mode...",
            "Building a wall around your notifications...",
            "Going off the grid...",
        ],

        // System info
        "get_system_info": [
            "Performing a full body scan on your Mac...",
            "Checking your Mac's vital signs...",
            "Running diagnostics... beep boop...",
        ],

        // Calendar/Reminders
        "create_reminder": [
            "Adding to your 'definitely won't forget' list...",
            "Creating a reminder you'll probably ignore...",
            "Future you will thank present you...",
        ],
        "create_calendar_event": [
            "Blocking off time in your very busy schedule...",
            "Scheduling your social obligations...",
            "Your calendar just got a little sadder...",
        ],

        // Clipboard
        "set_clipboard_text": [
            "Copying to your digital pocket...",
            "Ctrl+C'd that for ya...",
        ],

        // Notifications
        "show_notification": [
            "Sending you a ping from the void...",
            "Crafting an annoying popup just for you...",
        ],

        // Memory
        "save_memory": [
            "Storing that in my brain vault...",
            "I'll remember this forever (or until you delete it)...",
            "Tattooing this into my memory...",
        ],

        // Automation
        "create_automation_rule": [
            "Teaching your Mac a new trick...",
            "Programming your digital butler...",
            "Setting up a booby trap (the good kind)...",
        ],

        // Window management
        "tile_windows_side_by_side": [
            "Playing Tetris with your windows...",
            "Organizing your chaos...",
        ],
        "move_window": [
            "Relocating your window's real estate...",
        ],
    ]

    // MARK: - Generic fallback messages for unknown tools

    private let genericToolMessages = [
        "Doing mysterious computer things...",
        "Working my magic...",
        "Hold my beer...",
        "Trust me, I know what I'm doing...",
        "Executing plan B (there was no plan A)...",
        "Making things happen behind the scenes...",
        "This is where the magic happens...",
        "Pulling strings in the digital realm...",
        "Operating heavy machinery...",
        "Deploying the secret weapon...",
        "Running classified operations...",
        "Activating the thing that does the stuff...",
        "Doing what the AI does best...",
        "Loading awesome.exe...",
        "Compiling some vibes...",
        "Allocating maximum effort...",
        "Engaging warp drive...",
        "Flipping the right switches...",
    ]

    // MARK: - Result Messages

    private let successPrefixes = [
        "Done! ",
        "Boom! ",
        "Ez. ",
        "Mission accomplished. ",
        "Your wish is my command. ",
        "Nailed it. ",
        "Consider it done. ",
        "No cap, that's handled. ",
        "Just like that. ",
        "Piece of cake. ",
    ]

    // MARK: - Health Check Messages

    private let healthyMessages = [
        "Your Mac is vibing",
        "Your Mac is absolutely thriving",
        "Your Mac is built different",
        "Your Mac woke up and chose excellence",
        "Your Mac passed the vibe check",
        "Your Mac is in its prime",
    ]

    private let diskWarningMessages = [
        "Your Mac is getting a little thicc",
        "Storage looking packed... time to Marie Kondo some files?",
        "Your disk is giving 'I have too many screenshots' energy",
    ]

    // MARK: - Public API

    func funnyThinking() -> String {
        thinkingMessages.randomElement()!
    }

    func funnyToolStatus(toolName: String, step: Int, total: Int) -> String {
        let messages = toolMessages[toolName] ?? genericToolMessages
        let msg = messages.randomElement()!
        return "\(msg) (\(step)/\(total))"
    }

    func funnyResult(_ original: String) -> String {
        let prefix = successPrefixes.randomElement()!
        // Keep original if it's short enough, otherwise just use the prefix
        if original.count < 60 {
            return "\(prefix)\(original)"
        }
        return original
    }

    func funnyHealthMessage(isHealthy: Bool, diskUsedPercent: Int) -> String {
        if !isHealthy && diskUsedPercent >= 85 {
            return diskWarningMessages.randomElement()!
        }
        return healthyMessages.randomElement()!
    }
}
