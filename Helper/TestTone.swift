import CoreAudio
import Foundation

/// Plays three short beeps straight to one display, with its own IO proc on that device.
/// Independent of the tap, so it works while nothing else is playing. The helper's process is
/// excluded from the tap, so the beeps are neither captured nor muted.
final class TestTone {
    private static var active: [TestTone] = []
    private static let lock = NSLock()

    private let device: AudioObjectID
    private var procID: AudioDeviceIOProcID?
    // IO-thread-only state after start().
    private var position = 0
    private var phase: Float = 0
    private let sampleRate: Double
    private let totalFrames: Int
    private let beepFrames: Int

    private init(device: AudioObjectID) {
        self.device = device
        let rate = device.audioValue(address(kAudioDevicePropertyNominalSampleRate), initial: Float64(48000)) ?? 48000
        sampleRate = rate
        totalFrames = Int(rate * 0.9)
        beepFrames = Int(rate * 0.15)
    }

    static func play(on device: AudioObjectID) {
        let tone = TestTone(device: device)
        guard tone.start() else { return }
        lock.lock(); active.append(tone); lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.1) {
            tone.stop()
            lock.lock(); active.removeAll { $0 === tone }; lock.unlock()
        }
    }

    private func start() -> Bool {
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned self] _, _, _, output, _ in
            self.render(UnsafeMutableAudioBufferListPointer(output))
        }
        guard status == noErr, let proc else { log("Test tone: could not create IO proc: \(status)"); return false }
        procID = proc
        let startStatus = AudioDeviceStart(device, proc)
        if startStatus != noErr { log("Test tone: could not start: \(startStatus)"); stop(); return false }
        return true
    }

    private func stop() {
        guard let proc = procID else { return }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
        procID = nil
    }

    private func render(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * MemoryLayout<Float>.size)
        let step = Float(2.0 * Double.pi * 660.0 / sampleRate)
        let startPosition = position, startPhase = phase
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            let dst = data.assumingMemoryBound(to: Float.self)
            var p = startPosition, ph = startPhase
            for frame in 0..<frames {
                var sample: Float = 0
                if p < totalFrames, (p / beepFrames) % 2 == 0 {
                    sample = 0.25 * sinf(ph)
                    ph += step
                    if ph > Float(2.0 * Double.pi) { ph -= Float(2.0 * Double.pi) }
                }
                p += 1
                for channel in 0..<channels { dst[frame * channels + channel] = sample }
            }
            position = p
            phase = ph
        }
    }
}
