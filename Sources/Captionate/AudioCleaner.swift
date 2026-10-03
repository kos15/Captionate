import Foundation
import AVFoundation

/// On-device voice cleanup: rumble high-pass, mains-hum notches, a smooth noise gate and loudness
/// normalisation. Writes the processed audio to a temporary CAF that the exporter uses instead of the
/// original sound.
enum AudioCleaner {
    static let sampleRate = 48_000.0

    /// Returns nil when the file has no audio.
    static func process(_ url: URL, denoise: Bool, normalize doNormalize: Bool) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        var (left, right) = try decode(asset: asset, track: track)
        guard !left.isEmpty else { return nil }
        try Task.checkCancellation()

        if denoise {
            let filters: [Biquad] = [.highPass(85), .notch(50), .notch(60), .notch(100), .notch(120)]
            for proto in filters {
                var l = proto, r = proto
                l.process(&left)
                r.process(&right)
            }
            try Task.checkCancellation()
            gate(&left, &right)
        }
        if doNormalize { normalize(&left, &right) }
        try Task.checkCancellation()
        return try write(left, right)
    }

    // MARK: Decode / encode

    private static func decode(asset: AVAsset, track: AVAssetTrack) throws -> ([Float], [Float]) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var left: [Float] = [], right: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            left.reserveCapacity(left.count + chunk.count / 2)
            right.reserveCapacity(right.count + chunk.count / 2)
            var i = 0
            while i + 1 < chunk.count {
                left.append(chunk[i])
                right.append(chunk[i + 1])
                i += 2
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return (left, right)
    }

    private static func write(_ left: [Float], _ right: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("captionate-audio-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = 65_536
        var offset = 0
        while offset < left.count {
            let n = min(chunk, left.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let channels = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = AVAudioFrameCount(n)
            left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress! + offset, count: n) }
            right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress! + offset, count: n) }
            try file.write(from: buffer)
            offset += n
        }
        return url
    }

    // MARK: DSP

    /// RBJ biquad filter.
    private struct Biquad {
        var b0, b1, b2, a1, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        static func highPass(_ f: Double, q: Double = 0.707) -> Biquad {
            let w = 2 * Double.pi * f / sampleRate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        static func notch(_ f: Double, q: Double = 25) -> Biquad {
            let w = 2 * Double.pi * f / sampleRate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            return Biquad(b0: Float(1 / a0), b1: Float(-2 * c / a0), b2: Float(1 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        mutating func process(_ samples: inout [Float]) {
            for i in samples.indices {
                let x = samples[i]
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x
                y2 = y1; y1 = y
                samples[i] = y
            }
        }
    }

    /// Ducks the background between phrases: the noise floor is estimated from the quietest 10 ms frames.
    private static func gate(_ left: inout [Float], _ right: inout [Float]) {
        let frame = Int(sampleRate * 0.01)
        let count = left.count / frame
        guard count > 20 else { return }
        var rms = [Float](repeating: 0, count: count)
        for f in 0..<count {
            var sum: Float = 0
            for i in (f * frame)..<((f + 1) * frame) {
                let m = (left[i] + right[i]) * 0.5
                sum += m * m
            }
            rms[f] = (sum / Float(frame)).squareRoot()
        }
        let noiseFloor = rms.sorted()[count * 15 / 100]
        let threshold = max(noiseFloor * 3, 0.001)

        let floorGain: Float = 0.15     // about -16 dB between phrases, never fully silent
        var target = [Float](repeating: floorGain, count: count)
        var hold = 0
        for f in 0..<count {
            if rms[f] > threshold {
                hold = 12                           // 120 ms hold
                for k in max(0, f - 3)..<f { target[k] = 1 }   // 30 ms look-ahead
            }
            if hold > 0 { target[f] = 1; hold -= 1 }
        }

        let attack = 1 - exp(-1 / Float(sampleRate * 0.005))
        let release = 1 - exp(-1 / Float(sampleRate * 0.15))
        var gain = target[0]
        for i in left.indices {
            let t = target[min(i / frame, count - 1)]
            gain += (t - gain) * (t > gain ? attack : release)
            left[i] *= gain
            right[i] *= gain
        }
    }

    /// Brings speech to a consistent level (≈ -20 dBFS RMS) without clipping (peak ≤ -1 dBFS).
    private static func normalize(_ left: inout [Float], _ right: inout [Float]) {
        var peak: Float = 0
        var sum: Double = 0
        var active = 0
        for i in left.indices {
            let a = max(abs(left[i]), abs(right[i]))
            peak = max(peak, a)
            if a > 0.01 {
                sum += Double(left[i] * left[i] + right[i] * right[i]) / 2
                active += 1
            }
        }
        guard peak > 0, active > 0 else { return }
        let rms = Float((sum / Double(active)).squareRoot())
        let gain = min(0.1 / max(rms, 1e-4), 0.89 / peak, 8)
        for i in left.indices {
            left[i] *= gain
            right[i] *= gain
        }
    }
}
