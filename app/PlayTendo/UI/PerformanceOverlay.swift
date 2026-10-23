import SwiftUI
import Darwin
#if os(macOS)
import IOKit
#endif

/// Affichage des performances (Réglages, menu pause › Image) : coupé par défaut.
enum PerformanceSettings {
    static let key = "affichagePerformances"
}

/// Mesures prises chaque seconde pendant une partie : images par seconde et vitesse du jeu (données par le moteur,
/// ou comptées par l'app), processeur et mémoire utilisés par PlayTendo, batterie (iPhone, iPad), état thermique
/// (iOS ne donne pas de température en degrés), carte graphique (Mac seulement : iOS ne la donne à aucune app).
@MainActor
final class PerformanceMonitor: ObservableObject {
    struct Reading: Equatable {
        var fps: Double?
        var speed: Double?
        var cpu: Double?
        var memoryMB: Double?
        var gpu: Double?
        var battery: Int?
        var thermal: ProcessInfo.ThermalState = .nominal
    }

    @Published private(set) var reading = Reading()
    private var timer: Timer?
    private var lastFrames: UInt64?
    private var lastTime: CFAbsoluteTime = 0

    func start(_ session: EmulatorSession) {
        guard timer == nil else { return }
#if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
#endif
        sample(session)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak session] _ in
            MainActor.assumeIsolated {
                if let session { self?.sample(session) }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastFrames = nil
    }

    private func sample(_ session: EmulatorSession) {
        var reading = Reading()
        let now = CFAbsoluteTimeGetCurrent()
        if session.state == .running, let performance = session.performanceSample() {
            if let fps = performance.fps {
                reading.fps = fps
                reading.speed = performance.speed
            } else if let frames = performance.frames {
                if let last = lastFrames, frames >= last, now > lastTime {
                    let fps = Double(frames - last) / (now - lastTime)
                    reading.fps = fps
                    if let nominal = performance.nominalFPS, nominal > 0 { reading.speed = fps / nominal * 100 }
                }
                lastFrames = frames
                lastTime = now
            }
        } else {
            lastFrames = nil
        }
        reading.cpu = Self.cpuUsage()
        reading.memoryMB = Self.memoryMB()
        reading.thermal = ProcessInfo.processInfo.thermalState
#if os(iOS)
        let level = UIDevice.current.batteryLevel
        if level >= 0 { reading.battery = Int((level * 100).rounded()) }
#else
        reading.gpu = Self.gpuUsage()
#endif
        self.reading = reading
    }

    /// Processeur utilisé par PlayTendo, en part de tout le processeur (100 % : tous les cœurs pleins).
    private static func cpuUsage() -> Double? {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if result == KERN_SUCCESS && info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE)
            }
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        return total * 100 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Mémoire utilisée par PlayTendo (celle que compte iOS pour fermer une app qui en prend trop).
    private static func memoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

#if os(macOS)
    /// Mac : occupation de la carte graphique (statistiques publiées par son pilote).
    private static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }
#endif
}

/// La ligne des performances, discrète, en haut à gauche de l'image du jeu.
struct PerformanceOverlay: View {
    let session: EmulatorSession
    let paused: Bool
    @StateObject private var monitor = PerformanceMonitor()

    var body: some View {
        let reading = monitor.reading
        HStack(spacing: 7) {
            if paused {
                Text(tr("PAUSE"))
            } else if let fps = reading.fps {
                Text("\(Int(fps.rounded())) FPS")
                    .foregroundStyle(.white)
                if let speed = reading.speed {
                    Text("\(Int(speed.rounded())) %")
                        .foregroundStyle(speed < 95 ? Color.orange : Color.white.opacity(0.75))
                }
            }
            if let cpu = reading.cpu { Text("CPU \(Int(cpu.rounded())) %") }
            if let gpu = reading.gpu { Text("GPU \(Int(gpu.rounded())) %") }
            if let memory = reading.memoryMB { Text(tr("\(Int(memory.rounded())) Mo")) }
            if let battery = reading.battery {
                HStack(spacing: 2) {
                    Image(systemName: battery > 60 ? "battery.75" : battery > 30 ? "battery.50" : "battery.25")
                    Text("\(battery) %")
                }
            }
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                Text(Self.thermalLabel(reading.thermal))
            }
            .foregroundStyle(Self.thermalColor(reading.thermal))
        }
        .font(Neon.mono(10, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.75))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.45)))
        .onAppear { monitor.start(session) }
        .onDisappear { monitor.stop() }
        .accessibilityHidden(true)
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: tr("Normal")
        case .fair: tr("Chaud")
        case .serious: tr("Très chaud")
        case .critical: tr("Critique")
        @unknown default: "?"
        }
    }

    private static func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: Color.white.opacity(0.75)
        case .fair: .yellow
        case .serious: .orange
        default: .red
        }
    }
}
