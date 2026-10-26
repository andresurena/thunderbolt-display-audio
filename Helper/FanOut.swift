import CoreAudio
import Foundation

enum FanOutError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case message(String)

    var description: String {
        switch self {
        case let .status(call, status): return "\(call) failed: \(status) (\(fourCharCode(UInt32(bitPattern: status))))"
        case let .message(text): return text
        }
    }
}

/// Taps the audio every other process sends to the main display (the default output device), mutes it
/// there, and replays it through every display from one private aggregate device:
///   sub-devices [main display (clock), other displays (drift-corrected)] + tap (drift-corrected).
/// The IO callback copies the tap's stereo into each display's output stream, routed per display.
/// No input device is involved, so macOS shows no microphone indicator.
final class FanOut {
    /// The default output device. The keyboard keys drive its hardware volume; we mirror it to the rest.
    let mainDisplay: DeviceInfo
    /// All displays, main first. Output streams come in this order.
    let displays: [DeviceInfo]

    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var procID: AudioDeviceIOProcID?
    private let listenerQueue: DispatchQueue
    private var controlListener: AudioObjectPropertyListenerBlock?
    private let controlSelectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]

    // Tables the IO thread reads. Fixed-size raw memory: no Swift arrays on the real-time path.
    private static let maxOutputBuffers = 32
    private static let maxDisplays = 16
    /// Output buffer index -> display index, or -1 for anything unexpected (silenced).
    private let outputBufferDisplay = UnsafeMutablePointer<Int32>.allocate(capacity: FanOut.maxOutputBuffers)
    /// Display index -> ChannelMode raw value.
    private let modeTable = UnsafeMutablePointer<Int32>.allocate(capacity: FanOut.maxDisplays)
    /// Display index -> linear software gain (<= 1). Only below 1 when a level trim needs more boost
    /// than a display's hardware volume can give: the other displays are attenuated instead.
    private let gainTable = UnsafeMutablePointer<Float>.allocate(capacity: FanOut.maxDisplays)
    /// Display index -> level trim in dB (control side only).
    private var trims: [Float]
    /// Index of the tap's stereo buffer in the input list; found on the first IO cycle.
    private var sourceBufferIndex = -1

    /// Host time of the last non-silent buffer, written from the IO thread.
    private(set) var lastSignalHostTime: UInt64 = 0

    // Dropout diagnostics, written on the IO thread or the HAL notification queue, read by the health timer.
    /// IO cycles whose output timeline did not continue where the previous one ended (a skipped cycle).
    private(set) var discontinuities: UInt64 = 0
    /// kAudioDeviceProcessorOverload notifications on the aggregate (the IO proc missed its deadline).
    private(set) var overloads: UInt64 = 0
    /// Buffer size of the aggregate, for the log.
    private(set) var bufferFrames: UInt32 = 0
    private var expectedOutputSampleTime: Float64 = -1
    /// Tap input cycles whose timeline jumped (input arrived late or was dropped).
    private(set) var inputDiscontinuities: UInt64 = 0
    /// Single silent cycles sandwiched between cycles with sound: a hole in the tapped audio.
    private(set) var inputHoles: UInt64 = 0
    private var expectedInputSampleTime: Float64 = -1
    private var previousCycleHadSignal = false
    private var silentCyclesInRow = 0
    private var overloadListener: AudioObjectPropertyListenerBlock?


    // Balance gains (left speaker, right speaker), written from the control thread.
    private var gainLeft: Float = 1
    private var gainRight: Float = 1

    init(mainDisplay: DeviceInfo, otherDisplays: [DeviceInfo], modes: [ChannelMode], trims: [Float], balance: Float, listenerQueue: DispatchQueue) {
        self.mainDisplay = mainDisplay
        self.displays = Array(([mainDisplay] + otherDisplays).prefix(FanOut.maxDisplays))
        self.listenerQueue = listenerQueue
        self.trims = (0..<min(otherDisplays.count + 1, FanOut.maxDisplays)).map { $0 < trims.count ? trims[$0] : 0 }
        outputBufferDisplay.initialize(repeating: -1, count: FanOut.maxOutputBuffers)
        gainTable.initialize(repeating: 1, count: FanOut.maxDisplays)
        modeTable.initialize(repeating: ChannelMode.stereo.rawValue, count: FanOut.maxDisplays)
        for (index, mode) in modes.prefix(FanOut.maxDisplays).enumerated() { modeTable[index] = mode.rawValue }
        setBalance(balance)
    }

    deinit {
        outputBufferDisplay.deallocate()
        modeTable.deallocate()
        gainTable.deallocate()
    }

    func start() throws {
        // Only touch a rate that differs. Setting it, even to the same value, reconfigures the device and
        // the tap then misses any stream that was already playing (it hears silence until that app restarts).
        for device in displays {
            let rateAddress = address(kAudioDevicePropertyNominalSampleRate)
            let current = device.id.audioValue(rateAddress, initial: Float64(0)) ?? 0
            guard current != Config.sampleRate else { continue }
            let status = device.id.setAudioValue(rateAddress, Config.sampleRate)
            log(status == noErr ? "Changed \(device.label) from \(Int(current)) to \(Int(Config.sampleRate)) Hz"
                                : "Could not set \(device.label) to \(Int(Config.sampleRate)) Hz: \(status)")
        }

        // 1. Tap everything other processes send to the main display, and mute it there while we read it.
        let excluded = Devices.ownProcessObjectID().map { [$0] } ?? []
        if excluded.isEmpty { log("Warning: could not find own process object; the tap may include this helper") }
        let description = CATapDescription(excludingProcesses: excluded, deviceUID: mainDisplay.uid, stream: 0)
        description.name = Config.tapName
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw FanOutError.status("AudioHardwareCreateProcessTap", tapStatus) }
        tapID = tap
        tapDescription = description

        // 2. One aggregate of all displays plus the tap, clocked by the main display.
        var subDevices: [[String: Any]] = []
        for (index, display) in displays.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: display.uid,
                kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1,
            ])
        }
        let aggregateDescription: [String: Any] = [
            // Unique per build: if a previous copy died without tearing its aggregate down, Core Audio keeps
            // that UID reserved and creating another with the same UID fails ('nope') until coreaudiod restarts.
            kAudioAggregateDeviceUIDKey: "\(Config.aggregateUID).\(getpid()).\(UUID().uuidString.prefix(8))",
            kAudioAggregateDeviceNameKey: Config.aggregateName,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: mainDisplay.uid,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &id)
        guard createStatus == noErr else { throw FanOutError.status("AudioHardwareCreateAggregateDevice", createStatus) }
        aggregateID = id

        // The aggregate finishes assembling its streams asynchronously.
        let expectedOutputChannels = displays.count * 2
        // Displays' microphone streams plus the tap. All must be present before the input is restricted,
        // or a late microphone stream would escape the restriction and light the microphone indicator.
        let expectedInputStreams = displays.reduce(0) { $0 + $1.id.streamChannels(scope: kAudioObjectPropertyScopeInput).count } + 1
        var inputLayout: [Int] = []
        var outputLayout: [Int] = []
        for _ in 0..<40 {
            inputLayout = id.streamChannels(scope: kAudioObjectPropertyScopeInput)
            outputLayout = id.streamChannels(scope: kAudioObjectPropertyScopeOutput)
            if outputLayout.reduce(0, +) >= expectedOutputChannels, inputLayout.contains(2),
               inputLayout.count >= expectedInputStreams { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard inputLayout.contains(2) else {
            throw FanOutError.message("Aggregate has no stereo tap stream (input layout \(inputLayout))")
        }
        if inputLayout.count < expectedInputStreams {
            log("Warning: aggregate has \(inputLayout.count) input streams, expected \(expectedInputStreams)")
        }
        deactivateMicrophoneStreams(of: id, layout: inputLayout)

        // Map output buffers to displays in sub-device order.
        var bufferIndex = 0
        for (displayIndex, display) in displays.enumerated() {
            for _ in display.id.streamChannels(scope: kAudioObjectPropertyScopeOutput) where bufferIndex < FanOut.maxOutputBuffers {
                outputBufferDisplay[bufferIndex] = Int32(displayIndex)
                bufferIndex += 1
            }
        }
        let mapping = (0..<min(outputLayout.count, FanOut.maxOutputBuffers)).map { Int(outputBufferDisplay[$0]) }

        let aggregateRate = id.audioValue(address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        if aggregateRate != Config.sampleRate {
            id.setAudioValue(address(kAudioDevicePropertyNominalSampleRate), Config.sampleRate)
            log("Changed the aggregate from \(Int(aggregateRate)) to \(Int(Config.sampleRate)) Hz")
        }
        log("Aggregate \(id) ready: input streams \(inputLayout), output streams \(outputLayout), output buffer -> display \(mapping)")

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [unowned self] _, input, inputTime, output, outputTime in
            self.trackTimeline(outputTime, frames: output.pointee.mBuffers.mDataByteSize)
            self.trackInputTimeline(inputTime, frames: output.pointee.mBuffers.mDataByteSize)
            self.render(input: input, output: output)
        }
        guard procStatus == noErr, let proc else { throw FanOutError.status("AudioDeviceCreateIOProcIDWithBlock", procStatus) }
        procID = proc
        restrictInputToTap(aggregate: id, proc: proc, layout: inputLayout)

        let startStatus = AudioDeviceStart(id, proc)
        guard startStatus == noErr else { throw FanOutError.status("AudioDeviceStart", startStatus) }

        installControlMirror()
        installOverloadCounter()
        bufferFrames = id.audioValue(address(kAudioDevicePropertyBufferFrameSize), initial: UInt32(0)) ?? 0
        mirrorControls()
    }

    func stop() {
        if let listener = overloadListener {
            var addr = address(kAudioDeviceProcessorOverload)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, listenerQueue, listener)
            overloadListener = nil
        }
        if let listener = controlListener {
            for selector in controlSelectors {
                var addr = address(selector, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementWildcard)
                AudioObjectRemovePropertyListenerBlock(mainDisplay.id, &addr, listenerQueue, listener)
            }
            controlListener = nil
        }
        if let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
    }

    /// A tap-backed aggregate reports "not running" while the tapped device is idle, so only liveness
    /// counts here. Displays coming and going are handled by the device-list listener.
    var isHealthy: Bool {
        aggregateID != kAudioObjectUnknown && aggregateID.isAlive
    }

    /// The displays carry a microphone each. The helper never uses them: switch every input stream
    /// that is not the tap's stereo stream off.
    private func deactivateMicrophoneStreams(of aggregate: AudioObjectID, layout: [Int]) {
        let streams = aggregate.audioObjectIDs(address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput))
        var count = 0
        for (index, stream) in streams.enumerated() where index < layout.count && layout[index] != 2 {
            if stream.setAudioValue(address(kAudioStreamPropertyIsActive), UInt32(0)) == noErr { count += 1 }
        }
        if count > 0 { log("Deactivated \(count) microphone stream(s) in the aggregate") }
    }

    /// Tell the HAL this IO proc only reads the tap's stereo stream. The displays' microphone streams are
    /// then never started, so macOS has no microphone use to report (deactivating the streams alone
    /// does not survive the device going idle and restarting).
    private func restrictInputToTap(aggregate: AudioObjectID, proc: AudioDeviceIOProcID, layout: [Int]) {
        let count = layout.count
        guard count > 0 else { return }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer?>.size + MemoryLayout<UInt32>.size
        let byteCount = headerSize + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: MemoryLayout<UnsafeMutableRawPointer?>.size, as: UInt32.self)
        var usageAddress = address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        var size = UInt32(byteCount)
        let getStatus = AudioObjectGetPropertyData(aggregate, &usageAddress, 0, nil, &size, raw)
        guard getStatus == noErr else { log("Could not read input stream usage: \(getStatus)"); return }
        let flags = (raw + headerSize).assumingMemoryBound(to: UInt32.self)
        var kept: [Int] = []
        for index in 0..<count {
            let isTap = layout[index] == 2
            flags[index] = isTap ? 1 : 0
            if isTap { kept.append(index) }
        }
        let setStatus = AudioObjectSetPropertyData(aggregate, &usageAddress, 0, nil, UInt32(byteCount), raw)
        if setStatus == noErr {
            log("Input limited to tap stream \(kept); \(count - kept.count) microphone stream(s) never started")
        } else {
            log("Could not limit input streams: \(setStatus) (\(fourCharCode(UInt32(bitPattern: setStatus))))")
        }
    }

    // MARK: Dropout diagnostics

    private func installOverloadCounter() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.overloads &+= 1 }
        overloadListener = listener
        var addr = address(kAudioDeviceProcessorOverload)
        AudioObjectAddPropertyListenerBlock(aggregateID, &addr, listenerQueue, listener)
    }

    /// IO thread. Each cycle's output should start exactly where the previous one ended.
    private func trackTimeline(_ time: UnsafePointer<AudioTimeStamp>, frames byteSize: UInt32) {
        guard time.pointee.mFlags.contains(.sampleTimeValid) else { return }
        let start = time.pointee.mSampleTime
        if expectedOutputSampleTime >= 0, abs(start - expectedOutputSampleTime) > 0.5 { discontinuities &+= 1 }
        let frames = Float64(byteSize) / Float64(2 * MemoryLayout<Float>.size)
        expectedOutputSampleTime = start + frames
    }

    /// IO thread. Same check for the tap side.
    private func trackInputTimeline(_ time: UnsafePointer<AudioTimeStamp>, frames byteSize: UInt32) {
        guard time.pointee.mFlags.contains(.sampleTimeValid) else { return }
        let start = time.pointee.mSampleTime
        if expectedInputSampleTime >= 0, abs(start - expectedInputSampleTime) > 0.5 { inputDiscontinuities &+= 1 }
        expectedInputSampleTime = start + Float64(byteSize) / Float64(2 * MemoryLayout<Float>.size)
    }

    // MARK: Routing controls (any thread; the IO thread picks the values up on its next cycle)

    func setMode(_ mode: ChannelMode, forDisplayAt index: Int) {
        guard index >= 0, index < displays.count else { return }
        modeTable[index] = mode.rawValue
    }

    /// Call on the listener queue.
    func setTrim(_ value: Float, forDisplayAt index: Int) {
        guard index >= 0, index < trims.count else { return }
        trims[index] = value
        mirrorControls()
    }

    func mode(forDisplayAt index: Int) -> ChannelMode {
        guard index >= 0, index < displays.count else { return .stereo }
        return ChannelMode(rawValue: modeTable[index]) ?? .stereo
    }

    /// -1 = fully left, 0 = centre, 1 = fully right. Like the classic macOS slider: the side you move
    /// toward stays at full level and the other side is attenuated linearly down to silence.
    func setBalance(_ balance: Float) {
        let clamped = max(-1, min(1, balance))
        gainLeft = clamped > 0 ? 1 - clamped : 1
        gainRight = clamped < 0 ? 1 + clamped : 1
    }

    // MARK: Real-time path. No allocation, no locks, no Swift runtime calls that might take them.

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        // The tap is the only stereo input stream; find it once. Deactivated mic streams may or may
        // not still appear in the list, so this cannot be computed from the layout ahead of time.
        if sourceBufferIndex < 0 {
            var found = -1
            for index in 0..<inputList.count where inputList[index].mNumberChannels == 2 && inputList[index].mDataByteSize > 0 {
                found = index
                break
            }
            sourceBufferIndex = found
        }

        guard sourceBufferIndex >= 0, sourceBufferIndex < inputList.count, let sourceData = inputList[sourceBufferIndex].mData else {
            for buffer in outputList {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        let source = inputList[sourceBufferIndex]
        let sourceChannels = Int(source.mNumberChannels)
        let sourceFrames = Int(source.mDataByteSize) / (sourceChannels * MemoryLayout<Float>.size)
        let src = sourceData.assumingMemoryBound(to: Float.self)
        let rightOffset = sourceChannels > 1 ? 1 : 0

        var hasSignal = false
        for i in 0..<(sourceFrames * sourceChannels) where src[i] != 0 { hasSignal = true; break }
        if hasSignal { lastSignalHostTime = mach_absolute_time() }
        // A lone silent cycle between two cycles with sound is a hole in the tap, heard as a click.
        if hasSignal {
            if silentCyclesInRow == 1, previousCycleHadSignal { inputHoles &+= 1 }
            silentCyclesInRow = 0
            previousCycleHadSignal = true
        } else {
            if silentCyclesInRow == 0 { /* first silent cycle after sound */ } else { previousCycleHadSignal = false }
            silentCyclesInRow += 1
        }

        for (index, buffer) in outputList.enumerated() {
            guard let destData = buffer.mData else { continue }
            let displayIndex = index < FanOut.maxOutputBuffers ? outputBufferDisplay[index] : -1
            if displayIndex < 0 {
                memset(destData, 0, Int(buffer.mDataByteSize))
                continue
            }

            let destChannels = Int(buffer.mNumberChannels)
            let destFrames = Int(buffer.mDataByteSize) / (destChannels * MemoryLayout<Float>.size)
            let dst = destData.assumingMemoryBound(to: Float.self)

            let mode = modeTable[Int(displayIndex)]
            let frames = min(sourceFrames, destFrames)
            let trimGain = gainTable[Int(displayIndex)]
            let left = gainLeft * trimGain, right = gainRight * trimGain

            if mode == ChannelMode.stereo.rawValue, left == 1, right == 1,
               destChannels == sourceChannels, buffer.mDataByteSize == source.mDataByteSize {
                memcpy(destData, sourceData, Int(buffer.mDataByteSize))
                continue
            }

            // A display playing one channel sits on that side, so the whole display takes that side's
            // gain. Otherwise the display's own left/right speakers (channel 0/1) take the gains.
            for frame in 0..<frames {
                let base = frame * sourceChannels
                switch mode {
                case ChannelMode.leftOnly.rawValue:
                    let value = src[base] * left
                    for channel in 0..<destChannels { dst[frame * destChannels + channel] = value }
                case ChannelMode.rightOnly.rawValue:
                    let value = src[base + rightOffset] * right
                    for channel in 0..<destChannels { dst[frame * destChannels + channel] = value }
                case ChannelMode.mono.rawValue:
                    let value = 0.5 * (src[base] + src[base + rightOffset])
                    for channel in 0..<destChannels {
                        dst[frame * destChannels + channel] = value * (channel % 2 == 0 ? left : right)
                    }
                default:
                    for channel in 0..<destChannels {
                        dst[frame * destChannels + channel] = src[base + channel % sourceChannels] * (channel % 2 == 0 ? left : right)
                    }
                }
            }
            if destFrames > frames {
                memset(dst + frames * destChannels, 0, (destFrames - frames) * destChannels * MemoryLayout<Float>.size)
            }
        }
    }

    // MARK: Volume and mute mirroring

    /// The keyboard keys drive the main display's hardware volume and mute. Copy every change
    /// to the other displays so they stay in step.
    private func installControlMirror() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.mirrorControls() }
        controlListener = listener
        for selector in controlSelectors {
            var addr = address(selector, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementWildcard)
            AudioObjectAddPropertyListenerBlock(mainDisplay.id, &addr, listenerQueue, listener)
        }
    }

    /// Every other display follows the main display's level in dB plus its trim relative to the main one.
    /// When a display cannot reach its target (hardware range), the difference is made up in software
    /// by attenuating the other displays, so the balance between screens is always kept and nothing clips.
    func mirrorControls() {
        let count = displays.count
        let mainDB = outputDecibels(of: mainDisplay)
        if let mainDB {
            var residual = [Float](repeating: 0, count: count)
            for index in 1..<max(count, 1) {
                let display = displays[index]
                let target = mainDB + trims[index] - trims[0]
                let applied = setOutputDecibels(of: display, target)
                residual[index] = applied.map { target - $0 } ?? 0
            }
            let headroom = residual.max() ?? 0
            for index in 0..<count {
                gainTable[index] = Float(pow(10.0, Double(residual[index] - headroom) / 20.0))
            }
        }
        let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if let mute: UInt32 = mainDisplay.id.audioValue(muteAddress, initial: 0) {
            for display in displays.dropFirst() where display.id.hasAudioProperty(muteAddress) {
                display.id.setAudioValue(muteAddress, mute)
            }
        }
    }

    /// Output elements that carry a volume control: the main element if present, else channels 1 and 2.
    private func volumeElements(of display: DeviceInfo) -> [AudioObjectPropertyElement] {
        let main = address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput)
        if display.id.hasAudioProperty(main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter {
            display.id.hasAudioProperty(address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput, element: $0))
        }
    }

    private func outputDecibels(of display: DeviceInfo) -> Float? {
        guard let element = volumeElements(of: display).first else { return nil }
        return display.id.audioValue(address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput, element: element), initial: Float32(0))
    }

    /// Sets the display's volume to `decibels`, clamped to its range. Returns the dB actually applied.
    private func setOutputDecibels(of display: DeviceInfo, _ decibels: Float) -> Float? {
        var applied: Float?
        for element in volumeElements(of: display) {
            let rangeAddress = address(kAudioDevicePropertyVolumeRangeDecibels, scope: kAudioObjectPropertyScopeOutput, element: element)
            var value = decibels
            if let range: AudioValueRange = display.id.audioValue(rangeAddress, initial: AudioValueRange()) {
                value = min(max(value, Float(range.mMinimum)), Float(range.mMaximum))
            }
            display.id.setAudioValue(address(kAudioDevicePropertyVolumeDecibels, scope: kAudioObjectPropertyScopeOutput, element: element), value)
            applied = value
        }
        return applied
    }
}
