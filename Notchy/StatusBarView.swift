import SwiftUI
import AppKit

@Observable
class StatusBarModel {
    var nowPlaying: String?
    var battery: String?
    var time: String = ""

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        refreshTime()
        refreshBattery()
        refreshNowPlaying()
    }

    private func refreshTime() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        time = f.string(from: Date())
    }

    private func refreshBattery() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "batt"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pct = output.range(of: #"\d+%"#, options: .regularExpression)
                .map { String(output[$0]) }
            DispatchQueue.main.async { self.battery = pct }
        }
    }

    private func refreshNowPlaying() {
        DispatchQueue.global(qos: .background).async {
            // Try Spotify first, then Apple Music
            let script = """
            tell application "System Events"
              set spotRunning to (name of processes) contains "Spotify"
              set musicRunning to (name of processes) contains "Music"
            end tell
            if spotRunning then
              tell application "Spotify"
                if player state is playing then
                  return (name of current track) & " - " & (artist of current track)
                end if
              end tell
            end if
            if musicRunning then
              tell application "Music"
                if player state is playing then
                  return (name of current track) & " - " & (artist of current track)
                end if
              end tell
            end if
            return ""
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            let track = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmed = track.isEmpty ? nil : String(track.prefix(50))
            DispatchQueue.main.async { self.nowPlaying = trimmed }
        }
    }
}

struct StatusBarView: View {
    @State private var model = StatusBarModel()

    var body: some View {
        HStack(spacing: 0) {
            if let track = model.nowPlaying {
                segment(track, color: Color(hex: "#cba6f7"))
                separator()
            }
            if let batt = model.battery {
                segment(batt, color: Color(hex: "#a6e3a1"))
                separator()
            }
            segment(model.time, color: Color(hex: "#cdd6f4"))
        }
        .font(.system(size: 10.5, weight: .regular).monospacedDigit())
    }

    private func segment(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundColor(color)
            .lineLimit(1)
    }

    private func separator() -> some View {
        Text(" | ")
            .foregroundColor(Color(hex: "#45475a"))
    }
}

private extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}
