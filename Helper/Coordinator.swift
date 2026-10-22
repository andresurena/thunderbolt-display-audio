import CoreAudio
import Foundation

/// What the menu shows for one display.
struct DisplaySummary {
    let index: Int
    let uid: String
    let label: String
    let mode: ChannelMode
}

struct Snapshot {
    let status: String
    let displays: [DisplaySummary]
}

/// Watches the device list and keeps one FanOut alive for the current set of displays.
final class Coordinator {
    private let queue = DispatchQueue(label: "com.andresurena.ThunderboltDisplays.helper")
    private var fanOut: FanOut?
    private var pendingRebuild: DispatchWorkItem?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var healthTimer: DispatchSourceTimer?

    private var status = "Starting…"
    private var signalWasFlowing = false
    private var displayCount = 0

    func start() {
        // Deliver HAL notifications on dispatch queues instead of a run loop.
        let nullRunLoop: CFRunLoop? = nil
        AudioObjectID(kAudioObjectSystemObject).setAudioValue(address(kAudioHardwarePropertyRunLoop), nullRunLoop)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(after: 1.0, reason: "device list changed")
        }
        devicesListener = listener
        var devicesAddress = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, listener)

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
            fanOut?.stop()
            fanOut = nil
        }
    }

    // MARK: Menu-facing API (call from the main thread)

    func snapshot() -> Snapshot {
        queue.sync {
            let displays = (fanOut?.displays ?? []).enumerated().map { index, device in
                DisplaySummary(index: index, uid: device.uid, label: device.label,
                               mode: fanOut?.mode(forDisplayAt: index) ?? .stereo)
            }
            return Snapshot(status: status, displays: displays)
        }
    }

    func requestRebuild() {
        scheduleRebuild(after: 0, reason: "requested from menu", force: true)
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
        guard let current = fanOut else { return }
        if !current.isHealthy {
            log("Fan-out is no longer running; rebuilding")
            rebuild(force: true, reason: "health check")
            return
        }
        let flowing = current.lastSignalHostTime != 0 && hostTimeToSeconds(mach_absolute_time() - current.lastSignalHostTime) < 2
        if flowing != signalWasFlowing {
            signalWasFlowing = flowing
            log(flowing ? "Signal detected" : "Signal stopped")
            status = playingStatus()
        }
    }

    private func playingStatus() -> String {
        let base = displayCount == 1 ? "Playing through 1 display" : "Playing through \(displayCount) displays"
        return base + (signalWasFlowing ? " · audio flowing" : " · silent")
    }

    private func hostTimeToSeconds(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    private func rebuild(force: Bool, reason: String) {
        let virtualDevice = Devices.virtualDevice()
        let displays = Devices.displays()

        if !force, let current = fanOut, current.virtualDevice == virtualDevice, current.displays == displays {
            return
        }

        log("Rebuilding (\(reason))")
        fanOut?.stop()
        fanOut = nil

        guard let virtualDevice else {
            status = "Virtual device not installed"
            log("Virtual device \(Config.virtualDeviceUID) not found")
            return
        }
        guard !displays.isEmpty else {
            status = "No Thunderbolt Display speakers found"
            log("No devices named \"\(Config.displayDeviceName)\" with output channels")
            return
        }

        let modes = displays.map { ChannelMode.load(for: $0.uid) }
        let candidate = FanOut(virtualDevice: virtualDevice, displays: displays, modes: modes, listenerQueue: queue)
        do {
            try candidate.start()
            fanOut = candidate
            let routing = zip(displays, modes).map { "\($0.label) [\($0.id)] -> \($1.shortTitle)" }.joined(separator: ", ")
            log("Playing \"\(virtualDevice.name)\" through \(routing)")
            displayCount = displays.count
            signalWasFlowing = false
            status = playingStatus()
        } catch {
            candidate.stop()
            log("Could not start fan-out: \(error)")
            status = "Error: \(error)"
            scheduleRebuild(after: 5, reason: "retry after error", force: true)
        }
    }
}
