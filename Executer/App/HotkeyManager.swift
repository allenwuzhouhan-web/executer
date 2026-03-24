import Carbon

/// Manages global hotkey registration via Carbon API.
/// Extracted from AppState to isolate Carbon API concerns.
class HotkeyManager {
    private var hotkeyRef: EventHotKeyRef?
    private var voiceHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onToggle: (() -> Void)?
    private var onVoice: (() -> Void)?

    func register(onToggle: @escaping () -> Void, onVoice: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onVoice = onVoice

        // Install a Carbon event handler for hotkey events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

            if hotkeyID.id == 1 {
                DispatchQueue.main.async {
                    print("[Hotkey] Cmd+Shift+Space pressed!")
                    manager.onToggle?()
                }
            } else if hotkeyID.id == 2 {
                DispatchQueue.main.async {
                    print("[Hotkey] Cmd+Shift+V pressed — voice!")
                    manager.onVoice?()
                }
            }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandlerRef)

        // Register Cmd+Shift+Space
        // Space = keycode 49, Cmd = cmdKey, Shift = shiftKey
        var hotkeyID = EventHotKeyID(signature: OSType(0x4558_4543), id: 1) // "EXEC"
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)

        let status = RegisterEventHotKey(UInt32(kVK_Space), modifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &hotkeyRef)

        if status == noErr {
            print("[Hotkey] Registered Cmd+Shift+Space successfully")
        } else {
            print("[Hotkey] Failed to register hotkey, status: \(status)")
        }

        // Register Cmd+Shift+V for voice input
        // V = keycode 9
        var voiceHotkeyID = EventHotKeyID(signature: OSType(0x4558_4543), id: 2) // "EXEC" id 2
        let voiceStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), modifiers, voiceHotkeyID,
                                              GetApplicationEventTarget(), 0, &voiceHotkeyRef)
        if voiceStatus == noErr {
            print("[Hotkey] Registered Cmd+Shift+V (voice) successfully")
        } else {
            print("[Hotkey] Failed to register voice hotkey, status: \(voiceStatus)")
        }
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = voiceHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}
