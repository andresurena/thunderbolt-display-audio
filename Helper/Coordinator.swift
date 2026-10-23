import CoreAudio
import Foundation

enum Side {
    case left, right, unknown

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .unknown: return ""
        }
    }
}

/// What the menu shows for one display.
struct DisplaySummary {
    let uid: String
    let serial: String
    let label: String
    let mode: ChannelMode
    let trim: Float
    let isMain: Bool
    let side: Side
}

struct Snapshot {
    let status: String
    let isActive: Bool
    /// Displays present on the system, ordered left to right by physical placement.
    let displays: [DisplaySummary]
    let balance: Float
    /// Serial of the display the user pinned to the left, or nil when placement is automatic.
    let manualLeftSerial: String?
    /// True when every display could be matched to a screen in the Displays arrangement.
    let arrangementKnown: Bool
    /// The Mac's output device is already one of the displays (routing may still be starting).
    let outputIsDisplay: Bool
}

private let balanceKey = "balance"

/// Watches the device list and the default output device, and keeps one FanOut alive while the
/// default output is one of the Thunderbolt Displays.
final class Coordinator {
    private let queue = DispatchQueue(label: "com.andresurena.ThunderboltDisplays.helper")
    private var fanOut: FanOut?
    private var pendingRebuild: DispatchWorkItem?
    private var hardwareListener: AudioObjectPropertyListenerBlock?
    private var healthTimer: DispatchSourceTimer?

    private var status = "Starting…"
    private var balance = Float(UserDefaults.standard.double(forKey: balanceKey))
    private var signalWasFlowing = false
    private var knownDisplays: [DeviceInfo] = []

    /// FanOut.start() can block for as long as macOS waits on the audio-capture permission prompt
    /// (indefinitely while the screen is locked). It runs here, never on `queue`, so the menu stays live.
    private let startQueue = DispatchQueue(label: "com.andresurena.ThunderboltDisplays.start")
    private var starting: FanOut?
    private var startGeneration = 0
    private var rebuildAfterStart = false
    private var forceAfterStart = false
    private var pendingBalanceSave: DispatchWorkItem?

    func start() {
        // Deliver HAL notifications on dispatch queues instead of a run loop.
        let nullRunLoop: CFRunLoop? = nil
        AudioObjectID(kAudioObjectSystemObject).setAudioValue(address(kAudioHardwarePropertyRunLoop), nullRunLoop)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(after: 1.0, reason: "devices or default output changed")
        }
        hardwareListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer

        queue.async { self.rebuild(force: true, reason: "startup") }
    }

    func stop() {
        queue.sync {
            if let save = pendingBalanceSave, !save.isCancelled { save.perform() }
            pendingRebuild?.cancel()
            healthTimer?.cancel()
            startGeneration += 1   // a start still in flight will tear itself down
            fanOut?.stop()
            fanOut = nil
        }
    }

    // MARK: Menu-facing API (call from the main thread)

    func snapshot() -> Snapshot {
        queue.sync {
            let devices = fanOut?.displays ?? knownDisplays
            let ordered = Placement.leftToRight(devices.map(\.serial))
            let arrangementKnown = devices.allSatisfy { ScreenMatch.displayID(forSerial: $0.serial) != nil }
            let positioned = arrangementKnown || Placement.manualLeftSerial != nil
            let displays: [DisplaySummary] = ordered.enumerated().compactMap { position, serial in
                guard let device = devices.first(where: { $0.serial == serial }) else { return nil }
                let index = fanOut?.displays.firstIndex(of: device)
                let side: Side = !positioned || devices.count < 2 ? .unknown
                    : position == 0 ? .left : position == ordered.count - 1 ? .right : .unknown
                return DisplaySummary(
                    uid: device.uid, serial: device.serial, label: device.label,
                    mode: index.map { fanOut!.mode(forDisplayAt: $0) } ?? ChannelMode.load(for: device.uid),
                    trim: LevelTrim.load(for: device.uid),
                    isMain: index == 0, side: side)
            }
            return Snapshot(status: status, isActive: fanOut != nil, displays: displays, balance: balance,
                            manualLeftSerial: Placement.manualLeftSerial, arrangementKnown: arrangementKnown,
                            outputIsDisplay: devices.contains { $0.id == Devices.defaultOutputID() })
        }
    }

    func requestRebuild() {
        scheduleRebuild(after: 0, reason: "requested from menu", force: true)
    }

    /// Make the first Thunderbolt Display the system output; the rebuild follows from the HAL notification.
    func useDisplaysAsOutput() {
        queue.async {
            let current = Devices.defaultOutputID()
            guard !self.knownDisplays.contains(where: { $0.id == current }),
                  let first = self.knownDisplays.first else { return }
            let status = Devices.setDefaultOutput(first.id)
            log("Set default output to \(first.label): \(status)")
        }
    }

    func setMode(_ mode: ChannelMode, forDisplayUID uid: String) {
        queue.async {
            mode.save(for: uid)
            guard let current = self.fanOut, let index = current.displays.firstIndex(where: { $0.uid == uid }) else { return }
            current.setMode(mode, forDisplayAt: index)
            log("Routing: \(current.displays[index].label) -> \(mode.shortTitle)")
        }
    }

    /// Physically leftmost display plays the left channel, rightmost the right channel.
    func splitByPlacement() {
        queue.async {
            guard let current = self.fanOut, current.displays.count >= 2 else { return }
            let order = Placement.leftToRight(current.displays.map(\.serial))
            for (index, display) in current.displays.enumerated() {
                let position = order.firstIndex(of: display.serial) ?? index
                let mode: ChannelMode = position == 0 ? .leftOnly : position == order.count - 1 ? .rightOnly : .mono
                mode.save(for: display.uid)
                current.setMode(mode, forDisplayAt: index)
            }
            let summary = order.compactMap { serial in
                current.displays.firstIndex { $0.serial == serial }.map { "\(current.displays[$0].label) -> \(current.mode(forDisplayAt: $0).shortTitle)" }
            }
            log("Routing by placement: \(summary.joined(separator: ", "))")
        }
    }

    /// Exchange left-only and right-only on every display.
    func swapLeftRight() {
        queue.async {
            guard let current = self.fanOut else { return }
            for (index, display) in current.displays.enumerated() {
                let mode = current.mode(forDisplayAt: index)
                let swapped: ChannelMode = mode == .leftOnly ? .rightOnly : mode == .rightOnly ? .leftOnly : mode
                swapped.save(for: display.uid)
                current.setMode(swapped, forDisplayAt: index)
            }
            log("Routing: swapped left and right")
        }
    }

    func setManualLeft(serial: String?) {
        queue.async {
            Placement.manualLeftSerial = serial
            log(serial.map { "Placement: \($0) pinned to the left" } ?? "Placement: automatic (Displays arrangement)")
        }
    }

    func setTrim(_ value: Float, forDisplayUID uid: String) {
        queue.async {
            LevelTrim.save(value, for: uid)
            if let current = self.fanOut, let index = current.displays.firstIndex(where: { $0.uid == uid }) {
                current.setTrim(value, forDisplayAt: index)
            }
            log("Level trim: \(uid.split(separator: ":").dropFirst(3).first ?? Substring(uid)) \(LevelTrim.describe(value))")
        }
    }

    func setAllStereo() {
        queue.async {
            guard let current = self.fanOut else { return }
            for (index, display) in current.displays.enumerated() {
                ChannelMode.stereo.save(for: display.uid)
                current.setMode(.stereo, forDisplayAt: index)
            }
            log("Routing: stereo on every display")
        }
    }

    /// Applied immediately; saved and logged once the slider has been still for half a second.
    func setBalance(_ value: Float) {
        queue.async {
            self.balance = max(-1, min(1, value))
            self.fanOut?.setBalance(self.balance)
            self.pendingBalanceSave?.cancel()
            let save = DispatchWorkItem {
                UserDefaults.standard.set(Double(self.balance), forKey: balanceKey)
                log("Balance: \(Coordinator.describeBalance(self.balance))")
            }
            self.pendingBalanceSave = save
            self.queue.asyncAfter(deadline: .now() + 0.5, execute: save)
        }
    }

    static func describeBalance(_ value: Float) -> String {
        let percent = Int((abs(value) * 100).rounded())
        if percent == 0 { return "centre" }
        return value < 0 ? "\(percent)% left" : "\(percent)% right"
    }

    /// Three beeps through one display, whether or not routing is active or anything is playing.
    func identify(displayUID uid: String) {
        queue.async {
            guard let display = (self.fanOut?.displays ?? self.knownDisplays).first(where: { $0.uid == uid }) else { return }
            log("Identify tone on \(display.label)")
            TestTone.play(on: display.id)
        }
    }

    // MARK: Internals (always on `queue`)

    private func scheduleRebuild(after delay: TimeInterval, reason: String, force: Bool = false) {
        queue.async {
            self.pendingRebuild?.cancel()
            let item = DispatchWorkItem { self.rebuild(force: force, reason: reason) }
            self.pendingRebuild = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func checkHealth() {
        guard starting == nil, let current = fanOut else { return }
        if !current.isHealthy {
            log("Fan-out is no longer running; rebuilding")
            rebuild(force: true, reason: "health check")
            return
        }
        // Read the IO thread's timestamp first: it can be newer than a "now" read before it.
        let last = current.lastSignalHostTime
        let now = mach_absolute_time()
        let flowing = last != 0 && hostTimeToSeconds(now >= last ? now - last : 0) < 2
        if flowing != signalWasFlowing {
            signalWasFlowing = flowing
            log(flowing ? "Signal detected" : "Signal stopped")
            status = playingStatus(current)
        }
    }

    private func playingStatus(_ current: FanOut) -> String {
        let count = current.displays.count
        let base = count == 1 ? "Playing through 1 display" : "Playing through \(count) displays"
        return base + (signalWasFlowing ? " · audio flowing" : " · silent")
    }

    private func hostTimeToSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    private func rebuild(force: Bool, reason: String) {
        if starting != nil {
            // A start is in flight (possibly waiting on the permission prompt). Re-evaluate once it ends.
            rebuildAfterStart = true
            forceAfterStart = forceAfterStart || force
            return
        }
        let displays = Devices.displays()
        knownDisplays = displays
        let defaultID = Devices.defaultOutputID()
        let main = displays.first { $0.id == defaultID }
        let others = displays.filter { $0.id != defaultID }

        if !force, let current = fanOut, current.mainDisplay == main, Array(current.displays.dropFirst()) == others {
            return
        }

        log("Rebuilding (\(reason))")
        fanOut?.stop()
        fanOut = nil
        signalWasFlowing = false

        guard !displays.isEmpty else {
            status = "No Thunderbolt Display speakers found"
            log("No devices named \"\(Config.displayDeviceName)\" with output channels")
            return
        }
        guard let main else {
            status = "Output is \(Devices.name(of: defaultID)); not routing"
            log("Default output \(Devices.name(of: defaultID)) [\(defaultID)] is not a Thunderbolt Display; idle")
            return
        }

        let ordered = [main] + others
        let modes = ordered.map { ChannelMode.load(for: $0.uid) }
        let trims = ordered.map { LevelTrim.load(for: $0.uid) }
        let candidate = FanOut(mainDisplay: main, otherDisplays: others, modes: modes, trims: trims, balance: balance, listenerQueue: queue)
        let routing = zip(ordered, zip(modes, trims)).map { "\($0.label) [\($0.id)] -> \($1.0.shortTitle), trim \(LevelTrim.describe($1.1))" }.joined(separator: ", ")
        startGeneration += 1
        let generation = startGeneration
        starting = candidate
        rebuildAfterStart = false
        forceAfterStart = false
        status = "Starting…"

        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.starting === candidate, self.startGeneration == generation else { return }
            self.status = "Waiting for audio permission (System Settings › Privacy & Security)"
            log("Start is blocked, most likely on the system audio recording permission prompt")
        }

        startQueue.async { [weak self] in
            var failure: Error?
            do { try candidate.start() } catch { failure = error }
            guard let self else { candidate.stop(); return }
            self.queue.async { self.finishStart(candidate, generation: generation, failure: failure, routing: routing, mainLabel: main.label) }
        }
    }

    private func finishStart(_ candidate: FanOut, generation: Int, failure: Error?, routing: String, mainLabel: String) {
        starting = nil
        guard generation == startGeneration else { candidate.stop(); return }
        if let failure {
            candidate.stop()
            log("Could not start fan-out: \(failure)")
            status = "Error: \(failure)"
            scheduleRebuild(after: 5, reason: "retry after error", force: true)
            return
        }
        fanOut = candidate
        log("Tapping \(mainLabel) and playing through \(routing); balance \(Coordinator.describeBalance(balance))")
        status = playingStatus(candidate)
        if rebuildAfterStart {
            let force = forceAfterStart
            rebuildAfterStart = false
            forceAfterStart = false
            scheduleRebuild(after: 0.5, reason: "changes while starting", force: force)
        }
    }
}
