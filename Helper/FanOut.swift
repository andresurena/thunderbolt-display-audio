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
    /// Index of the tap's stereo buffer in the input list; found on the first IO cycle.
    private var sourceBufferIndex = -1

    /// Host time of the last non-silent buffer, written from the IO thread.
    private(set) var lastSignalHostTime: UInt64 = 0

    // Identify tone state, written from the control thread, consumed on the IO thread.
    private var identifyTarget: Int32 = -1
    private var identifyFramesRemaining: Int32 = 0
    private var identifyPosition: Int32 = 0
    private var tonePhase: Float = 0

    // Balance gains (left speaker, right speaker), written from the control thread.
    private var gainLeft: Float = 1
    private var gainRight: Float = 1

    init(mainDisplay: DeviceInfo, otherDisplays: [DeviceInfo], modes: [ChannelMode], balance: Float, listenerQueue: DispatchQueue) {
        self.mainDisplay = mainDisplay
        self.displays = Array(([mainDisplay] + otherDisplays).prefix(FanOut.maxDisplays))
        self.listenerQueue = listenerQueue
        outputBufferDisplay.initialize(repeating: -1, count: FanOut.maxOutputBuffers)
        modeTable.initialize(repeating: ChannelMode.stereo.rawValue, count: FanOut.maxDisplays)
        for (index, mode) in modes.prefix(FanOut.maxDisplays).enumerated() { modeTable[index] = mode.rawValue }
        setBalance(balance)
    }

    deinit {
        outputBufferDisplay.deallocate()
        modeTable.deallocate()
    }

    func start() throws {
        for device in displays {
            let status = device.id.setAudioValue(address(kAudioDevicePropertyNominalSampleRate), Config.sampleRate)
            if status != noErr { log("Could not set \(device.label) to \(Int(Config.sampleRate)) Hz: \(status)") }
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
            kAudioAggregateDeviceUIDKey: Config.aggregateUID,
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
        var inputLayout: [Int] = []
        var outputLayout: [Int] = []
        for _ in 0..<40 {
            inputLayout = id.streamChannels(scope: kAudioObjectPropertyScopeInput)
            outputLayout = id.streamChannels(scope: kAudioObjectPropertyScopeOutput)
            if outputLayout.reduce(0, +) >= expectedOutputChannels, inputLayout.contains(2) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard inputLayout.contains(2) else {
            throw FanOutError.message("Aggregate has no stereo tap stream (input layout \(inputLayout))")
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

        id.setAudioValue(address(kAudioDevicePropertyNominalSampleRate), Config.sampleRate)
        log("Aggregate \(id) ready: input streams \(inputLayout), output streams \(outputLayout), output buffer -> display \(mapping)")

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
        guard procStatus == noErr, let proc else { throw FanOutError.status("AudioDeviceCreateIOProcIDWithBlock", procStatus) }
        procID = proc
        restrictInputToTap(aggregate: id, proc: proc, layout: inputLayout)

        let startStatus = AudioDeviceStart(id, proc)
        guard startStatus == noErr else { throw FanOutError.status("AudioDeviceStart", startStatus) }

        installControlMirror()
        mirrorControls()
    }

    func stop() {
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

    // MARK: Routing controls (any thread; the IO thread picks the values up on its next cycle)

    func setMode(_ mode: ChannelMode, forDisplayAt index: Int) {
        guard index >= 0, index < displays.count else { return }
        modeTable[index] = mode.rawValue
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

    /// Three short beeps through one display only, so the user can tell which screen is which.
    func playIdentifyTone(forDisplayAt index: Int) {
        guard index >= 0, index < displays.count else { return }
        identifyPosition = 0
        identifyTarget = Int32(index)
        identifyFramesRemaining = Int32(Config.sampleRate * 0.9)
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

        var toneConsumed = false
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

            if identifyFramesRemaining > 0, displayIndex == identifyTarget, !toneConsumed {
                renderTone(into: dst, frames: destFrames, channels: destChannels)
                toneConsumed = true
                continue
            }

            let mode = modeTable[Int(displayIndex)]
            let frames = min(sourceFrames, destFrames)
            let left = gainLeft, right = gainRight

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

    private func renderTone(into dst: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        let beepFrames = Int32(Config.sampleRate * 0.15)
        let phaseStep = Float(2.0 * Double.pi * 660.0 / Config.sampleRate)
        for frame in 0..<frames {
            var sample: Float = 0
            if identifyFramesRemaining > 0 {
                if (identifyPosition / beepFrames) % 2 == 0 {
                    sample = 0.25 * sinf(tonePhase)
                    tonePhase += phaseStep
                    if tonePhase > Float(2.0 * Double.pi) { tonePhase -= Float(2.0 * Double.pi) }
                }
                identifyPosition += 1
                identifyFramesRemaining -= 1
            }
            for channel in 0..<channels { dst[frame * channels + channel] = sample }
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

    func mirrorControls() {
        let others = displays.dropFirst()
        guard !others.isEmpty else { return }
        let volume = mainDisplay.id.outputVolume(element: kAudioObjectPropertyElementMain)
            ?? mainDisplay.id.outputVolume(element: 1)
        if let volume {
            for display in others {
                for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                    let addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element)
                    if display.id.hasAudioProperty(addr) { display.id.setAudioValue(addr, volume) }
                }
            }
        }
        let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if let mute: UInt32 = mainDisplay.id.audioValue(muteAddress, initial: 0) {
            for display in others where display.id.hasAudioProperty(muteAddress) {
                display.id.setAudioValue(muteAddress, mute)
            }
        }
    }
}
