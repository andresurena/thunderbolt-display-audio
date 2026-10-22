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

/// Owns one private aggregate device: [virtual device (input, drift-corrected), display 1 (clock main),
/// display 2 (drift-corrected)]. Core Audio resamples the sub-devices onto display 1's clock, so the
/// IO callback is a plain copy of the virtual device's stereo into every display's output stream,
/// routed per display according to its ChannelMode.
final class FanOut {
    let virtualDevice: DeviceInfo
    let displays: [DeviceInfo]

    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sourceBufferIndex = 0
    private let listenerQueue: DispatchQueue
    private var controlListener: AudioObjectPropertyListenerBlock?
    private let controlSelectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]

    // Tables the IO thread reads. Fixed-size raw memory: no Swift arrays on the real-time path.
    private static let maxOutputBuffers = 32
    private static let maxDisplays = 16
    /// Output buffer index -> display index, or -1 for the virtual device's own output streams, which
    /// come first (sub-device order) and must only ever receive silence or the loopback echoes forever.
    private let outputBufferDisplay = UnsafeMutablePointer<Int32>.allocate(capacity: FanOut.maxOutputBuffers)
    /// Display index -> ChannelMode raw value.
    private let modeTable = UnsafeMutablePointer<Int32>.allocate(capacity: FanOut.maxDisplays)

    /// Host time of the last non-silent buffer, written from the IO thread.
    private(set) var lastSignalHostTime: UInt64 = 0

    // Identify tone state, written from the control thread, consumed on the IO thread.
    private var identifyTarget: Int32 = -1
    private var identifyFramesRemaining: Int32 = 0
    private var identifyPosition: Int32 = 0
    private var tonePhase: Float = 0

    init(virtualDevice: DeviceInfo, displays: [DeviceInfo], modes: [ChannelMode], listenerQueue: DispatchQueue) {
        self.virtualDevice = virtualDevice
        self.displays = Array(displays.prefix(FanOut.maxDisplays))
        self.listenerQueue = listenerQueue
        outputBufferDisplay.initialize(repeating: -1, count: FanOut.maxOutputBuffers)
        modeTable.initialize(repeating: ChannelMode.stereo.rawValue, count: FanOut.maxDisplays)
        for (index, mode) in modes.prefix(FanOut.maxDisplays).enumerated() { modeTable[index] = mode.rawValue }
    }

    deinit {
        outputBufferDisplay.deallocate()
        modeTable.deallocate()
    }

    func start() throws {
        for device in [virtualDevice] + displays {
            let status = device.id.setAudioValue(address(kAudioDevicePropertyNominalSampleRate), Config.sampleRate)
            if status != noErr { log("Could not set \(device.name) (\(device.uid)) to \(Int(Config.sampleRate)) Hz: \(status)") }
        }

        var subDevices: [[String: Any]] = [[
            kAudioSubDeviceUIDKey: virtualDevice.uid,
            kAudioSubDeviceDriftCompensationKey: 1,
        ]]
        for (index, display) in displays.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: display.uid,
                kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1,
            ])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Config.aggregateUID,
            kAudioAggregateDeviceNameKey: Config.aggregateName,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceMainSubDeviceKey: displays[0].uid,
        ]

        var id = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
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
        guard let sourceIndex = inputLayout.firstIndex(of: 2) else {
            throw FanOutError.message("Aggregate has no stereo input stream (input layout \(inputLayout))")
        }
        sourceBufferIndex = sourceIndex

        // Map output buffers to displays in sub-device order: virtual streams first, then each display's.
        var bufferIndex = virtualDevice.id.streamChannels(scope: kAudioObjectPropertyScopeOutput).count
        for (displayIndex, display) in displays.enumerated() {
            for _ in display.id.streamChannels(scope: kAudioObjectPropertyScopeOutput) where bufferIndex < FanOut.maxOutputBuffers {
                outputBufferDisplay[bufferIndex] = Int32(displayIndex)
                bufferIndex += 1
            }
        }
        let mapping = (0..<min(outputLayout.count, FanOut.maxOutputBuffers)).map { Int(outputBufferDisplay[$0]) }

        id.setAudioValue(address(kAudioDevicePropertyNominalSampleRate), Config.sampleRate)
        log("Aggregate \(id) ready: input streams \(inputLayout), output streams \(outputLayout), source stream #\(sourceIndex), output buffer -> display \(mapping)")

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
        guard procStatus == noErr, let proc else { throw FanOutError.status("AudioDeviceCreateIOProcIDWithBlock", procStatus) }
        procID = proc

        let startStatus = AudioDeviceStart(id, proc)
        guard startStatus == noErr else { throw FanOutError.status("AudioDeviceStart", startStatus) }

        installControlMirror()
        adoptDisplayLevel()
    }

    func stop() {
        if let listener = controlListener {
            for selector in controlSelectors {
                var addr = address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(virtualDevice.id, &addr, listenerQueue, listener)
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
    }

    var isHealthy: Bool {
        aggregateID != kAudioObjectUnknown && aggregateID.isAlive && aggregateID.isRunning
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

        guard sourceBufferIndex < inputList.count, let sourceData = inputList[sourceBufferIndex].mData else {
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

            if mode == ChannelMode.stereo.rawValue, destChannels == sourceChannels, buffer.mDataByteSize == source.mDataByteSize {
                memcpy(destData, sourceData, Int(buffer.mDataByteSize))
                continue
            }

            for frame in 0..<frames {
                let base = frame * sourceChannels
                switch mode {
                case ChannelMode.leftOnly.rawValue:
                    let value = src[base]
                    for channel in 0..<destChannels { dst[frame * destChannels + channel] = value }
                case ChannelMode.rightOnly.rawValue:
                    let value = src[base + rightOffset]
                    for channel in 0..<destChannels { dst[frame * destChannels + channel] = value }
                case ChannelMode.mono.rawValue:
                    let value = 0.5 * (src[base] + src[base + rightOffset])
                    for channel in 0..<destChannels { dst[frame * destChannels + channel] = value }
                default:
                    for channel in 0..<destChannels {
                        dst[frame * destChannels + channel] = src[base + channel % sourceChannels]
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

    /// The virtual device carries the volume and mute controls the keyboard keys drive.
    /// Every change is copied to the displays' own hardware controls.
    private func installControlMirror() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.mirrorControls() }
        controlListener = listener
        for selector in controlSelectors {
            var addr = address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(virtualDevice.id, &addr, listenerQueue, listener)
        }
    }

    func mirrorControls() {
        let volumeAddress = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        if let volume: Float32 = virtualDevice.id.audioValue(volumeAddress, initial: 0) {
            for display in displays {
                for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                    let addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element)
                    if display.id.hasAudioProperty(addr) { display.id.setAudioValue(addr, volume) }
                }
            }
        }
        let muteAddress = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if let mute: UInt32 = virtualDevice.id.audioValue(muteAddress, initial: 0) {
            for display in displays where display.id.hasAudioProperty(muteAddress) {
                display.id.setAudioValue(muteAddress, mute)
            }
        }
    }

    /// Start from the first display's current level so nothing jumps when the helper launches.
    private func adoptDisplayLevel() {
        let displayVolume = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1)
        if let level: Float32 = displays[0].id.audioValue(displayVolume, initial: 0) {
            virtualDevice.id.setAudioValue(address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput), level)
        }
        mirrorControls()
    }
}
