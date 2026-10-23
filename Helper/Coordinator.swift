import CoreAudio
import Foundation

/// What the menu shows for one display.
struct DisplaySummary {
    let index: Int
    let uid: String
    let label: String
    let mode: ChannelMode
    let isMain: Bool
}

struct Snapshot {
    let status: String
    let isActive: Bool
    /// Displays present on the system (whether or not the fan-out is running), main first when active.
    let displays: [DisplaySummary]
    let balance: Float
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
            let displays: [DisplaySummary]
            if let current = fanOut {
                displays = current.displays.enumerated().map { index, device in
                    DisplaySummary(index: index, uid: device.uid, label: device.label,
                                   mode: current.mode(forDisplayAt: index), isMain: index == 0)
                }
            } else {
                displays = knownDisplays.enumerated().map { index, device in
                    DisplaySummary(index: index, uid: device.uid, label: device.label,
                                   mode: ChannelMode.load(for: device.uid), isMain: false)
                }
            }
            return Snapshot(status: status, isActive: fanOut != nil, displays: displays, balance: balance)
        }
    }

    func requestRebuild() {
        scheduleRebuild(after: 0, reason: "requested from menu", force: true)
    }

    /// Make the first Thunderbolt Display the system output; the rebuild follows from the HAL notification.
    func useDisplaysAsOutput() {
        queue.async {
            guard let first = self.knownDisplays.first else { return }
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

    /// Left/right already assigned: swap them. Otherwise assign display 1 = left, display 2 = right.
    func swapOrSplitLeftRight() {
        queue.async {
            guard let current = self.fanOut, current.displays.count >= 2 else { return }
            let first = current.mode(forDisplayAt: 0), second = current.mode(forDisplayAt: 1)
            let (newFirst, newSecond): (ChannelMode, ChannelMode)
            if first == .leftOnly, second == .rightOnly { (newFirst, newSecond) = (.rightOnly, .leftOnly) }
            else if first == .rightOnly, second == .leftOnly { (newFirst, newSecond) = (.leftOnly, .rightOnly) }
            else { (newFirst, newSecond) = (.leftOnly, .rightOnly) }
            for (index, mode) in [newFirst, newSecond].enumerated() {
                mode.save(for: current.displays[index].uid)
                current.setMode(mode, forDisplayAt: index)
            }
            log("Routing: \(current.displays[0].label) -> \(newFirst.shortTitle), \(current.displays[1].label) -> \(newSecond.shortTitle)")
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

    func setBalance(_ value: Float) {
        queue.async {
            self.balance = max(-1, min(1, value))
            UserDefaults.standard.set(Double(self.balance), forKey: balanceKey)
            self.fanOut?.setBalance(self.balance)
            log("Balance: \(Coordinator.describeBalance(self.balance))")
        }
    }

    static func describeBalance(_ value: Float) -> String {
        let percent = Int((abs(value) * 100).rounded())
        if percent == 0 { return "centre" }
        return value < 0 ? "\(percent)% left" : "\(percent)% right"
    }

    func identify(displayUID uid: String) {
        queue.async {
            guard let current = self.fanOut, let index = current.displays.firstIndex(where: { $0.uid == uid }) else { return }
            log("Identify tone on \(current.displays[index].label)")
            current.playIdentifyTone(forDisplayAt: index)
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
        let flowing = current.lastSignalHostTime != 0 && hostTimeToSeconds(mach_absolute_time() - current.lastSignalHostTime) < 2
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
        let candidate = FanOut(mainDisplay: main, otherDisplays: others, modes: modes, balance: balance, listenerQueue: queue)
        let routing = zip(ordered, modes).map { "\($0.label) [\($0.id)] -> \($1.shortTitle)" }.joined(separator: ", ")
        startGeneration += 1
        let generation = startGeneration
        starting = candidate
        rebuildAfterStart = false
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
            rebuildAfterStart = false
            scheduleRebuild(after: 0.5, reason: "changes while starting")
        }
    }
}
