import SwiftUI

struct NotchSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var zoneX: String = ""
    @State private var zoneY: String = ""
    @State private var zoneW: String = ""
    @State private var zoneH: String = ""
    @State private var zoneSaved = false

    var body: some View {
        Form {
            Section("Notch Click Zone") {
                Text("Define the screen area that triggers the command bar when clicked. Coordinates use the screenshot tool system (origin = top-left, use Cmd+Shift+4 to find coordinates).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading) {
                        Text("X").font(.caption).foregroundStyle(.secondary)
                        TextField("X", text: $zoneX)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Y").font(.caption).foregroundStyle(.secondary)
                        TextField("Y", text: $zoneY)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Width").font(.caption).foregroundStyle(.secondary)
                        TextField("W", text: $zoneW)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    VStack(alignment: .leading) {
                        Text("Height").font(.caption).foregroundStyle(.secondary)
                        TextField("H", text: $zoneH)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                }

                HStack {
                    Button("Save Zone") {
                        let x = Double(zoneX) ?? 0
                        let y = Double(zoneY) ?? 0
                        let w = Double(zoneW) ?? 300
                        let h = Double(zoneH) ?? 38
                        let rect = CGRect(x: x, y: y, width: w, height: h)
                        print("[Settings] Saving zone: \(rect)")
                        appState.updateNotchZone(rect)
                        zoneSaved = true
                        print("[Settings] zoneSaved = \(zoneSaved)")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Reset to Auto") {
                        UserDefaults.standard.removeObject(forKey: "notch_click_zone")
                        let auto = NotchDetector.autoDetectZone()
                        appState.updateNotchZone(auto)
                        loadCurrentZone()
                        zoneSaved = true
                    }

                    if zoneSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Saved!")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text("Tip: Use Cmd+Shift+4 to find the coordinates of your notch area, then enter them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Shortcut") {
                Text("Cmd+Shift+Space also opens the command bar (works even without notch click).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            zoneSaved = false
            loadCurrentZone()
        }
    }

    private func loadCurrentZone() {
        let zone = NotchDetector.autoDetectZone()
        if let saved = UserDefaults.standard.string(forKey: "notch_click_zone") {
            let rect = NSRectFromString(saved)
            if rect.width > 0 {
                zoneX = String(Int(rect.origin.x))
                zoneY = String(Int(rect.origin.y))
                zoneW = String(Int(rect.size.width))
                zoneH = String(Int(rect.size.height))
                return
            }
        }
        zoneX = String(Int(zone.origin.x))
        zoneY = String(Int(zone.origin.y))
        zoneW = String(Int(zone.size.width))
        zoneH = String(Int(zone.size.height))
    }
}
