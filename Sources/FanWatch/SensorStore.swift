import Foundation
import SwiftUI
import Combine

enum SensorKind: String, Codable, CaseIterable {
    case temperature
    case fan

    var unit: String {
        switch self {
        case .temperature: return "°C"
        case .fan: return "RPM"
        }
    }
}

struct Sensor: Identifiable, Hashable {
    let key: String          // SMC key, e.g. "TC0P" or "F0Ac"
    let kind: SensorKind
    let name: String         // Friendly name if known, else the raw key

    var id: String { key }
}

struct Sample: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

/// Friendly names for common SMC keys (both Intel and Apple Silicon families).
/// Unknown keys just show their raw 4-char code — still fully usable.
enum SensorNames {
    static let known: [String: String] = [
        // Fans
        "F0Ac": "Fan 1", "F1Ac": "Fan 2", "F2Ac": "Fan 3", "F3Ac": "Fan 4",
        // Intel-era temperature keys
        "TC0P": "CPU Proximity", "TC0D": "CPU Die", "TC0E": "CPU Die (PECI)",
        "TC0F": "CPU Die (filtered)", "TCAD": "CPU Package",
        "TG0P": "GPU Proximity", "TG0D": "GPU Die",
        "TM0P": "Memory Proximity", "Tm0P": "Mainboard Proximity",
        "TA0P": "Ambient", "TA1P": "Ambient 2",
        "TH0P": "Drive Bay", "TW0P": "Airport Proximity",
        "Ts0P": "Palm Rest", "Ts1P": "Palm Rest 2",
        "TB0T": "Battery 1", "TB1T": "Battery 2", "TB2T": "Battery 3",
        "TN0P": "Northbridge", "TI0P": "Thunderbolt",
        // Apple Silicon families (best-effort labels)
        "Tp01": "CPU P-core 1", "Tp05": "CPU P-core 2", "Tp09": "CPU P-core 3",
        "Tp0D": "CPU P-core 4", "Tp0b": "CPU P-core 5", "Tp0f": "CPU P-core 6",
        "Tp0j": "CPU P-core 7", "Tp0n": "CPU P-core 8",
        "Tp0T": "CPU E-core", "Tp0t": "CPU E-core 2",
        "Tg05": "GPU 1", "Tg0D": "GPU 2", "Tg0L": "GPU 3", "Tg0T": "GPU 4",
        "TaLP": "Airflow Left", "TaRF": "Airflow Right",
        "TH0x": "NAND", "Ts0S": "Skin/Chassis",
        "TW0P ": "Wireless"
    ]

    static func name(for key: String) -> String {
        known[key] ?? key
    }
}

@MainActor
final class SensorStore: ObservableObject {
    @Published var sensors: [Sensor] = []
    @Published var latest: [String: Double] = [:]
    @Published var history: [String: [Sample]] = [:]
    @Published var selectedKeys: Set<String> = []
    @Published var errorMessage: String?
    @Published var isScanning = true

    // Flexible knobs, persisted across launches
    @AppStorage("refreshInterval") var refreshInterval: Double = 2.0 {
        didSet { restartTimer() }
    }
    @AppStorage("historySeconds") var historySeconds: Double = 300
    @AppStorage("menuBarKey") var menuBarKey: String = ""
    @AppStorage("useFahrenheit") var useFahrenheit: Bool = false
    @AppStorage("selectedKeysRaw") private var selectedKeysRaw: String = ""

    private var smc: SMCClient?
    private var timer: Timer?

    init() {
        selectedKeys = Set(selectedKeysRaw.split(separator: ",").map(String.init))
        Task { await start() }
    }

    func start() async {
        do {
            let client = try SMCClient()
            self.smc = client
            await discoverSensors(client: client)
            restartTimer()
        } catch {
            errorMessage = "Couldn't open the SMC: \(error). " +
                "This app must run on a real Mac (not a VM) and be built as a native binary."
            isScanning = false
        }
    }

    /// Scan every SMC key once; keep anything that looks like a temperature or fan sensor.
    private func discoverSensors(client: SMCClient) async {
        isScanning = true
        let found: [Sensor] = await Task.detached(priority: .userInitiated) { () -> [Sensor] in
            guard let metas = try? client.allKeys() else { return [] }
            var result: [Sensor] = []
            for meta in metas {
                // Fans: F<n>Ac = actual RPM
                if meta.key.count == 4, meta.key.hasPrefix("F"),
                   meta.key.hasSuffix("Ac"),
                   let v = try? client.readDouble(key: meta.key),
                   v >= 0, v < 20000 {
                    result.append(Sensor(key: meta.key, kind: .fan,
                                         name: SensorNames.name(for: meta.key)))
                    continue
                }
                // Temperatures: keys starting with T that decode into a sane °C range
                if meta.key.hasPrefix("T"),
                   ["flt ", "sp78", "sp87", "sp96", "ioft"].contains(meta.type),
                   let v = try? client.readDouble(key: meta.key),
                   v > 1, v < 130 {
                    result.append(Sensor(key: meta.key, kind: .temperature,
                                         name: SensorNames.name(for: meta.key)))
                }
            }
            return result.sorted {
                if $0.kind != $1.kind { return $0.kind == .fan }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value

        sensors = found
        isScanning = false

        // Sensible defaults on first launch: all fans + a few key temps
        if selectedKeys.isEmpty {
            let fans = found.filter { $0.kind == .fan }.map(\.key)
            let temps = found.filter { $0.kind == .temperature }.prefix(4).map(\.key)
            selectedKeys = Set(fans + temps)
            persistSelection()
        }
        if menuBarKey.isEmpty {
            menuBarKey = found.first(where: { $0.kind == .temperature })?.key
                ?? found.first?.key ?? ""
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = max(0.5, refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    private func poll() {
        guard let smc else { return }
        let keysToRead = selectedKeys.union([menuBarKey]).filter { !$0.isEmpty }
        let now = Date()
        let cutoff = now.addingTimeInterval(-historySeconds)

        for key in keysToRead {
            guard let value = try? smc.readDouble(key: key) else { continue }
            latest[key] = value
            var samples = history[key, default: []]
            samples.append(Sample(time: now, value: value))
            while let first = samples.first, first.time < cutoff {
                samples.removeFirst()
            }
            history[key] = samples
        }
    }

    func toggle(_ sensor: Sensor) {
        if selectedKeys.contains(sensor.key) {
            selectedKeys.remove(sensor.key)
            history[sensor.key] = nil
        } else {
            selectedKeys.insert(sensor.key)
        }
        persistSelection()
    }

    private func persistSelection() {
        selectedKeysRaw = selectedKeys.sorted().joined(separator: ",")
    }

    // MARK: - Display helpers

    func displayValue(for key: String) -> String {
        guard let sensor = sensors.first(where: { $0.key == key }),
              let value = latest[key] else { return "—" }
        return formatted(value, kind: sensor.kind)
    }

    func formatted(_ value: Double, kind: SensorKind) -> String {
        switch kind {
        case .fan:
            return "\(Int(value.rounded())) RPM"
        case .temperature:
            if useFahrenheit {
                return String(format: "%.1f°F", value * 9 / 5 + 32)
            }
            return String(format: "%.1f°C", value)
        }
    }

    func displayTemp(_ celsius: Double) -> Double {
        useFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    var menuBarText: String {
        guard !menuBarKey.isEmpty else { return "FanWatch" }
        return displayValue(for: menuBarKey)
    }
}
