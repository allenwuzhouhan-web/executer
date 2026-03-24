import Foundation

enum VoiceState: Equatable {
    case idle               // mic off, waiting for hotkey
    case backgroundListening // mic on, passively waiting for wake word
    case activated          // hotkey pressed, glow appearing
    case listening          // mic on, capturing command speech
    case dispatched         // command sent, mic off
    case error(String)      // something went wrong
}
