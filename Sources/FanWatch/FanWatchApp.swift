import SwiftUI

@main
struct FanWatchApp: App {
    @StateObject private var store = SensorStore()

    var body: some Scene {
        WindowGroup("FanWatch", id: "main") {
            ContentView()
                .environmentObject(store)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            // Live value in the menu bar, e.g. "48.2°C" or "1820 RPM"
            Text(store.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: SensorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.sensors.filter { store.selectedKeys.contains($0.key) }) { sensor in
                HStack {
                    Image(systemName: sensor.kind == .fan ? "fan" : "thermometer.medium")
                        .frame(width: 18)
                    Text(sensor.name)
                    Spacer()
                    Text(store.displayValue(for: sensor.key))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Divider()
            HStack {
                Button("Open FanWatch") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 260)
    }
}
