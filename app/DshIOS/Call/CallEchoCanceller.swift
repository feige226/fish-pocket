import AVFoundation

/// Takes her voice out of the microphone with WebRTC's echo canceller (AEC3, `native/aec3`), in
/// place of the system's call audio processing, which on an iPhone's speaker lets the first
/// second or so of each call through.
///
/// The reference is what the speaker was given to play, registered with the position on the
/// speaker's clock (`CallSpeaker`) it was placed at. A microphone packet comes with that clock
/// read as it arrived. Before each of its 10 ms frames is cleaned, the canceller analyses
/// everything that had played by then: the packet's last frame lines up with the reading, each
/// frame before it 10 ms earlier. Neither stream is ever cut or padded, so the two stay exact to
/// the sample and the canceller finds the delay between them itself; how many reference frames
/// come before a microphone frame varies from packet to packet, which it absorbs.
///
/// It works at 48 kHz, with the reference at 24 kHz and the microphone at 16 kHz, resampled
/// inside. One per call, so what it learns carries over from turn to turn. Not thread-safe.
final class CallEchoCanceller {
    static let renderRate = CallSpeaker.rate
    static let captureRate = 16_000
    static let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(captureRate), channels: 1, interleaved: false)!
    private static let renderFrame = renderRate / 100
    private static let captureFrame = captureRate / 100

    private let aec: OpaquePointer
    /// Microphone samples short of a whole frame, for the next packet.
    private var pending: [Float] = []
    /// What was placed on the speaker and is not analysed yet, by position on its clock.
    private var playback: [(start: Int, samples: [Float])] = []
    /// The next position of the reference to analyse.
    private var cursor = 0
    private var stats = Stats()
    #if DEBUG
    private var recording = Recording()
    #endif

    init?() {
        guard let aec = dsh_aec3_create(48_000, Int32(Self.renderRate), Int32(Self.captureRate)) else {
            CallDiagnostics.note("echo canceller unavailable")
            return nil
        }
        self.aec = aec
        CallDiagnostics.note("echo canceller: 48 kHz, reference 24 kHz, microphone 16 kHz")
    }

    deinit { dsh_aec3_destroy(aec) }

    /// `samples` play from `start` on the speaker's clock. Called once they are placed there.
    func addPlayback(_ samples: [Float], at start: Int) {
        guard !samples.isEmpty else { return }
        if let last = playback.last, start < last.start + last.samples.count {
            CallDiagnostics.note("echo reference overlaps the piece before it; dropped")
            return
        }
        playback.append((start, samples))
    }

    /// Nothing from `position` on plays: the user cut in. What already played stays, for its echo.
    func truncatePlayback(at position: Int) {
        playback = playback.compactMap { chunk in
            guard chunk.start < position else { return nil }
            return (chunk.start, Array(chunk.samples.prefix(position - chunk.start)))
        }
    }

    /// A packet of the 16 kHz microphone, with the speaker's clock read as it arrived. Returns it
    /// cleaned, in whole 10 ms frames; the rest waits for the next packet.
    func process(_ samples: [Float], played: Int) -> [Float] {
        var input = pending
        input.append(contentsOf: samples)
        let length = input.count / Self.captureFrame * Self.captureFrame
        var reference = [Float](repeating: 0, count: Self.renderFrame)
        for offset in stride(from: 0, to: length, by: Self.captureFrame) {
            // This frame's moment on the speaker's clock: the packet's last frame is the reading.
            let behind = (input.count - offset - Self.captureFrame) * Self.renderRate / Self.captureRate
            let target = max(0, played - behind) / Self.renderFrame * Self.renderFrame
            if target - cursor > 2 * Self.renderRate {
                CallDiagnostics.note(String(format: "echo canceller: the microphone fell %.1f s behind the speaker; skipping ahead", Double(target - cursor) / Double(Self.renderRate)))
                cursor = target
                playback.removeAll { $0.start + $0.samples.count <= cursor }
            }
            var fed = 0
            while cursor + Self.renderFrame <= target {
                readPlayback(into: &reference)
                reference.withUnsafeBufferPointer { dsh_aec3_analyze_render(aec, $0.baseAddress) }
                stats.noteRender(reference)
                #if DEBUG
                recording.write(speaker: reference)
                #endif
                cursor += Self.renderFrame
                fed += 1
            }
            input.withUnsafeMutableBufferPointer { buffer in
                let frame = UnsafeMutableBufferPointer(rebasing: buffer[offset..<offset + Self.captureFrame])
                stats.noteCapture(raw: frame)
                #if DEBUG
                recording.write(microphone: frame, after: fed)
                #endif
                dsh_aec3_process_capture(aec, frame.baseAddress)
                stats.noteCleaned(frame, aec: aec)
            }
        }
        pending = Array(input[length...])
        return Array(input[..<length])
    }

    /// The reference for the frame at `cursor`: whatever was placed there, silence elsewhere.
    private func readPlayback(into reference: inout [Float]) {
        let end = cursor + Self.renderFrame
        for index in reference.indices { reference[index] = 0 }
        for chunk in playback {
            if chunk.start >= end { break }
            let from = max(cursor, chunk.start), to = min(end, chunk.start + chunk.samples.count)
            if to > from {
                for position in from..<to { reference[position - cursor] = chunk.samples[position - chunk.start] }
            }
        }
        while let first = playback.first, first.start + first.samples.count <= end { playback.removeFirst() }
    }

    /// For the diagnostics: how loud the microphone was, before and after, while she played.
    private struct Stats {
        private var playing = false
        private var lastRender: Double = 0
        private var rendered: Double = 0
        private var raw: Double = 0
        private var cleaned: Double = 0
        private var frames = 0

        mutating func noteRender(_ samples: [Float]) {
            lastRender = Self.energy(samples)
            playing = lastRender > 1e-5
        }

        mutating func noteCapture(raw samples: UnsafeMutableBufferPointer<Float>) {
            guard playing else { return }
            raw += Self.energy(samples)
            rendered += lastRender
            frames += 1
        }

        mutating func noteCleaned(_ samples: UnsafeMutableBufferPointer<Float>, aec: OpaquePointer) {
            guard playing else { return }
            cleaned += Self.energy(samples)
            // Every second of her sound, with what the canceller says of itself.
            guard frames >= 100 else { return }
            let reference = 10 * log10(rendered / Double(frames) + 1e-12)
            let before = 10 * log10(raw / Double(frames) + 1e-12)
            let after = 10 * log10(cleaned / Double(frames) + 1e-12)
            let metrics = dsh_aec3_metrics(aec)
            CallDiagnostics.note(String(format: "echo canceller: reference %.0f dBFS, microphone %.0f dBFS → %.0f dBFS (%.0f dB out); it reports delay %d ms",
                                        reference, before, after, before - after, metrics.delay_ms))
            raw = 0; cleaned = 0; rendered = 0; frames = 0
        }

        private static func energy<C: Collection>(_ samples: C) -> Double where C.Element == Float {
            guard !samples.isEmpty else { return 0 }
            return Double(samples.reduce(Float(0)) { $0 + $1 * $1 }) / Double(samples.count)
        }
    }

    #if DEBUG
    /// Debug builds keep the first 90 s of each call exactly as the canceller got it, 16-bit mono
    /// in `Documents/call-echo/`: the reference (`-speaker.pcm`, 24 kHz), the raw microphone
    /// (`-microphone.pcm`, 16 kHz) and, for each microphone frame, how many reference frames were
    /// analysed just before it (`-steps.bin`, 16-bit), to replay through the canceller on a Mac.
    private struct Recording {
        private var speaker: FileHandle?
        private var microphone: FileHandle?
        private var steps: FileHandle?
        private var frames = 0
        private var opened = false

        mutating func write(speaker samples: [Float]) {
            if !opened { open() }
            guard frames < 9_000 else { return }
            speaker?.write(Self.int16(samples))
        }

        mutating func write(microphone samples: UnsafeMutableBufferPointer<Float>, after fed: Int) {
            if !opened { open() }
            frames += 1
            guard frames <= 9_000 else { return }
            microphone?.write(Self.int16(samples))
            var count = UInt16(min(fed, Int(UInt16.max))).littleEndian
            steps?.write(Data(bytes: &count, count: 2))
        }

        private static func int16<C: Collection>(_ samples: C) -> Data where C.Element == Float {
            var data = Data(count: samples.count * 2)
            data.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for (index, value) in samples.enumerated() { out[index] = Int16(max(-1, min(1, value)) * 32_767) }
            }
            return data
        }

        private mutating func open() {
            opened = true
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let folder = documents.appending(path: "call-echo")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only the latest few calls.
            let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in old.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(9) { try? FileManager.default.removeItem(at: file) }
            let stamp = Int(Date().timeIntervalSince1970)
            func handle(_ name: String) -> FileHandle? {
                let url = folder.appending(path: "\(stamp)-\(name)")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                return try? FileHandle(forWritingTo: url)
            }
            speaker = handle("speaker.pcm")
            microphone = handle("microphone.pcm")
            steps = handle("steps.bin")
            CallDiagnostics.note("echo recording: call-echo/\(stamp)-*")
        }
    }
    #endif
}
