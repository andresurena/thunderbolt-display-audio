import CoreAudio
import Foundation

// MARK: - Configuration

enum Config {
    static let aggregateUID = "com.andresurena.ThunderboltDisplays.fanout"
    static let aggregateName = "Thunderbolt Displays Fan-out"
    static let tapName = "Thunderbolt Displays Tap"
    /// Name the Thunderbolt Display's USB audio reports. Override with TBD_DISPLAY_DEVICE_NAME.
    static let displayDeviceName = ProcessInfo.processInfo.environment["TBD_DISPLAY_DEVICE_NAME"] ?? "Display Audio"
    static let sampleRate: Float64 = 48000
}

// MARK: - Logging

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

/// Appends to ~/Library/Logs/ThunderboltDisplays.log, whether the app was started by the install
/// script's LaunchAgent, as a login item, or by double-clicking it.
private let logQueue = DispatchQueue(label: "com.andresurena.ThunderboltDisplays.log")
private let logHandle: FileHandle? = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ThunderboltDisplays.log")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
}()

func log(_ message: String) {
    let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
    logQueue.async {
        if let handle = logHandle { handle.write(Data(line.utf8)) } else { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

func fourCharCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
}

// MARK: - Property helpers

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    func hasAudioProperty(_ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(self, &a)
    }

    func audioValue<T>(_ addr: AudioObjectPropertyAddress, initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(self, &a, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    @discardableResult
    func setAudioValue<T>(_ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(self, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    func audioString(_ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func audioObjectIDs(_ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Channel count of every stream in `scope`, in stream order.
    func streamChannels(scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Scalar value of a device output volume element, if the device exposes it.
    func outputVolume(element: AudioObjectPropertyElement) -> Float32? {
        audioValue(address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element), initial: Float32(0))
    }

    var isAlive: Bool {
        audioValue(address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1
    }

    var isRunning: Bool {
        audioValue(address(kAudioDevicePropertyDeviceIsRunning), initial: UInt32(0)) == 1
    }
}

// MARK: - Device discovery

struct DeviceInfo: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let outputChannels: Int
}

enum Devices {
    static func all() -> [DeviceInfo] {
        AudioObjectID(kAudioObjectSystemObject).audioObjectIDs(address(kAudioHardwarePropertyDevices)).map { id in
            DeviceInfo(
                id: id,
                uid: id.audioString(kAudioDevicePropertyDeviceUID) ?? "",
                name: id.audioString(kAudioDevicePropertyDeviceNameCFString) ?? "",
                transport: id.audioValue(address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0,
                outputChannels: id.streamChannels(scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
            )
        }
    }

    static func defaultOutputID() -> AudioObjectID {
        AudioObjectID(kAudioObjectSystemObject).audioValue(address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0)) ?? 0
    }

    static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        AudioObjectID(kAudioObjectSystemObject).setAudioValue(address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func name(of id: AudioObjectID) -> String {
        id.audioString(kAudioDevicePropertyDeviceNameCFString) ?? "device \(id)"
    }

    /// The HAL's process object for this process, needed to exclude ourselves from the tap.
    static func ownProcessObjectID() -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &object)
        }
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Every Thunderbolt Display speaker device, in a stable order.
    static func displays() -> [DeviceInfo] {
        all()
            .filter { $0.name == Config.displayDeviceName && $0.transport == kAudioDeviceTransportTypeUSB && $0.outputChannels >= 2 }
            .sorted { $0.uid < $1.uid }
    }
}

// MARK: - Channel routing

/// What each display plays. Raw values are read from the IO thread through a plain Int32 table.
enum ChannelMode: Int32, CaseIterable {
    case stereo = 0
    case leftOnly = 1
    case rightOnly = 2
    case mono = 3

    var title: String {
        switch self {
        case .stereo: return "Stereo (left + right)"
        case .leftOnly: return "Left channel only"
        case .rightOnly: return "Right channel only"
        case .mono: return "Mono (left + right mixed)"
        }
    }

    var shortTitle: String {
        switch self {
        case .stereo: return "Stereo"
        case .leftOnly: return "Left"
        case .rightOnly: return "Right"
        case .mono: return "Mono"
        }
    }

    private static func key(_ uid: String) -> String { "channelMode." + uid }

    static func load(for uid: String) -> ChannelMode {
        ChannelMode(rawValue: Int32(UserDefaults.standard.integer(forKey: key(uid)))) ?? .stereo
    }

    func save(for uid: String) {
        UserDefaults.standard.set(Int(rawValue), forKey: ChannelMode.key(uid))
    }
}

extension DeviceInfo {
    /// "Display Audio 1A2B3C4D": the serial fragment from the USB UID tells two identical displays apart.
    var label: String {
        let parts = uid.split(separator: ":")
        if parts.count >= 4, parts[2] == Substring(name) { return "\(name) \(parts[3])" }
        return name
    }
}

extension DeviceInfo {
    /// USB serial from the UID ("...:Display Audio:1A2B3C4D:2,1" -> "1A2B3C4D"); matches the screen's serial.
    var serial: String {
        let parts = uid.split(separator: ":")
        return parts.count >= 4 ? String(parts[3]) : uid
    }
}

// MARK: - Per-display level trim

/// Corrects one display sounding quieter than the other. Stored in dB per display UID and applied to the
/// display's hardware volume relative to the display the volume keys drive.
enum LevelTrim {
    static let steps: [Float] = [6, 4.5, 3, 1.5, 0, -1.5, -3, -4.5, -6]

    private static func key(_ uid: String) -> String { "levelTrim." + uid }

    static func load(for uid: String) -> Float {
        Float(UserDefaults.standard.double(forKey: key(uid)))
    }

    static func save(_ value: Float, for uid: String) {
        if value == 0 { UserDefaults.standard.removeObject(forKey: key(uid)) }
        else { UserDefaults.standard.set(Double(value), forKey: key(uid)) }
    }

    static func describe(_ value: Float) -> String {
        if value == 0 { return "0 dB" }
        let text = value.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", abs(value)) : String(format: "%.1f", abs(value))
        return (value > 0 ? "+" : "−") + text + " dB"
    }
}
