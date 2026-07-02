import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var store: SensorStore
    @State private var filter: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: Sidebar — pick which sensors to watch

    private var sidebar: some View {
        List {
            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if store.isScanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scanning SMC sensors…")
                }
            }
            ForEach(SensorKind.allCases, id: \.self) { kind in
                let matching = filteredSensors.filter { $0.kind == kind }
                if !matching.isEmpty {
                    Section(kind == .fan ? "Fans" : "Temperatures") {
                        ForEach(matching) { sensor in
                            SensorRow(sensor: sensor)
                        }
                    }
                }
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter sensors")
        .navigationTitle("Sensors")
    }

    private var filteredSensors: [Sensor] {
        guard !filter.isEmpty else { return store.sensors }
        return store.sensors.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            $0.key.localizedCaseInsensitiveContains(filter)
        }
    }

    // MARK: Detail — charts + settings

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsBar
                ChartCard(kind: .temperature)
                ChartCard(kind: .fan)
            }
            .padding(20)
        }
        .navigationTitle("FanWatch")
    }

    private var settingsBar: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading) {
                Text("Refresh: \(store.refreshInterval, specifier: "%.1f")s")
                    .font(.caption)
                Slider(value: $store.refreshInterval, in: 0.5...10, step: 0.5)
                    .frame(width: 160)
            }
            VStack(alignment: .leading) {
                Text("History: \(Int(store.historySeconds / 60)) min")
                    .font(.caption)
                Slider(value: $store.historySeconds, in: 60...3600, step: 60)
                    .frame(width: 160)
            }
            Toggle("°F", isOn: $store.useFahrenheit)
                .toggleStyle(.switch)
            Spacer()
            Picker("Menu bar", selection: $store.menuBarKey) {
                ForEach(store.sensors) { sensor in
                    Text(sensor.name).tag(sensor.key)
                }
            }
            .frame(maxWidth: 240)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Sensor row with live value

struct SensorRow: View {
    @EnvironmentObject var store: SensorStore
    let sensor: Sensor

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { store.selectedKeys.contains(sensor.key) },
                set: { _ in store.toggle(sensor) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sensor.name)
                    if sensor.name != sensor.key {
                        Text(sensor.key)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(store.displayValue(for: sensor.key))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chart card for one sensor kind

struct ChartCard: View {
    @EnvironmentObject var store: SensorStore
    let kind: SensorKind

    private var activeSensors: [Sensor] {
        store.sensors.filter { kind == $0.kind && store.selectedKeys.contains($0.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind == .fan ? "Fan Speed" : "Temperature")
                    .font(.headline)
                Spacer()
                // Live readout chips
                ForEach(activeSensors) { sensor in
                    if let v = store.latest[sensor.key] {
                        Text("\(sensor.name): \(store.formatted(v, kind: kind))")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }

            if activeSensors.isEmpty {
                Text("Select \(kind == .fan ? "a fan" : "a temperature sensor") in the sidebar to start charting.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(activeSensors) { sensor in
                        ForEach(store.history[sensor.key] ?? []) { sample in
                            LineMark(
                                x: .value("Time", sample.time),
                                y: .value("Value", kind == .temperature
                                          ? store.displayTemp(sample.value)
                                          : sample.value)
                            )
                            .foregroundStyle(by: .value("Sensor", sensor.name))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYAxisLabel(kind == .temperature
                                 ? (store.useFahrenheit ? "°F" : "°C")
                                 : "RPM")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
