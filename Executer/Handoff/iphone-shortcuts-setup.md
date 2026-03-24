# iPhone Handoff Setup via Shortcuts

Executer saves substantive outputs (research, drafts, summaries) to iCloud Drive. With a simple iPhone Shortcut, you can get notified on your iPhone and continue reading.

## Prerequisites

- iCloud Drive enabled on both your Mac and iPhone
- Both devices signed into the same Apple ID
- Shortcuts app on iPhone (built-in)

---

## Shortcut 1: "Read Executer Output" (Manual)

This shortcut reads the latest output and shows it to you.

### Steps to create:

1. Open **Shortcuts** on your iPhone
2. Tap **+** to create a new shortcut
3. Name it **"Read Executer Output"**
4. Add these actions in order:

**Action 1: Get File**
- Source: **iCloud Drive**
- Path: `Executer/Handoffs/latest.json`
- Error handling: If file doesn't exist, show "No recent outputs"

**Action 2: Get Dictionary from Input**
- Input: the file from step 1

**Action 3: Get Dictionary Value**
- Key: `topic`
- Save to variable: `Topic`

**Action 4: Get Dictionary Value**
- Key: `summary`
- Save to variable: `Summary`

**Action 5: Get Dictionary Value**
- Key: `filename`
- Save to variable: `Filename`

**Action 6: Show Alert**
- Title: `Topic` (variable)
- Message: `Summary` (variable)
- Buttons: "Open Full Output", "Dismiss"

**Action 7: If "Open Full Output" tapped**
- Get File from iCloud Drive: `Executer/Handoffs/[Filename]`
- Open File (opens in Files app or Quick Look)

5. Tap **Done**

### Usage:
- Say "Hey Siri, Read Executer Output"
- Or tap the shortcut from your home screen / widget

---

## Shortcut 2: "Executer Handoff Check" (Automated)

This automation checks every 30 minutes for new outputs and sends a notification.

### Steps to create:

1. Open **Shortcuts** → **Automation** tab
2. Tap **+** → **Create Personal Automation**
3. Choose **Time of Day**
   - Set to run **every 30 minutes** (or choose a specific schedule)
   - Or use **"When [App] is Opened"** → Files app (for on-demand checking)

4. Add these actions:

**Action 1: Get File**
- Source: iCloud Drive
- Path: `Executer/Handoffs/latest.json`

**Action 2: Get Dictionary from Input**

**Action 3: Get Dictionary Value**
- Key: `timestamp`
- Save to variable: `Timestamp`

**Action 4: Date**
- Get Current Date

**Action 5: Get Time Between Dates**
- Between `Timestamp` and Current Date
- In: Minutes

**Action 6: If** (time between < 60 minutes)

**Action 7: Get Dictionary Value**
- Key: `topic`

**Action 8: Show Notification**
- Title: "Continue from Mac"
- Body: `topic` value
- Tap to open: Run "Read Executer Output" shortcut

**End If**

5. Toggle off "Ask Before Running"
6. Tap **Done**

---

## Troubleshooting

**Files not syncing:**
- Check iCloud Drive is enabled: Settings → [Your Name] → iCloud → iCloud Drive
- Check the folder exists: Files app → iCloud Drive → Executer → Handoffs
- Force sync: open Files app, pull down to refresh

**Shortcut can't find file:**
- The file path is case-sensitive: `Executer/Handoffs/latest.json`
- Make sure Executer has written at least one output (check on Mac: `~/Library/Mobile Documents/com~apple~CloudDocs/Executer/Handoffs/`)

**No notifications:**
- Ensure Shortcuts has notification permission: Settings → Notifications → Shortcuts
- Check that the automation isn't set to "Ask Before Running"

---

## How It Works

1. When Executer generates a substantive response (>200 characters), it saves a `.md` file to iCloud Drive
2. It also updates `latest.json` with the topic, summary, and filename
3. Your iPhone Shortcut reads `latest.json` to know what's new
4. You can then open the full markdown file to read the complete output

The markdown files are automatically cleaned up after 30 days.
