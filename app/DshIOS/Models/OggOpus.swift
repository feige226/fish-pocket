import AVFoundation
import Foundation

/// 16 kHz mono 16-bit PCM in, Ogg Opus out (RFC 7845), one 20 ms packet at a time: the system's
/// Opus encoder, wrapped in Ogg pages written here. Volcengine's recognition takes it as
/// `"format": "ogg"` (`"codec": "opus"` optional). Each call's packets share one page, so feed
/// 100–200 ms at a time: smaller calls spend more on page headers. Not thread-safe; one per
/// connection, since the stream's header pages go out once.
final class OggOpusEncoder {
    private let input: AVAudioFormat
    private let opus: AVAudioFormat
    private let converter: AVAudioConverter?
    private let frameBytes: Int
    /// 48 kHz samples per input sample: Ogg Opus counts time at 48 kHz whatever the input rate.
    private let scale: Int64
    private let preSkip: Int
    private var writer = OggWriter()
    private var pending = Data()
    private var started = false
    private var finished = false
    /// Input samples given to the encoder, and 48 kHz samples of the packets written so far.
    private var consumed: Int64 = 0
    private var granule: Int64 = 0

    /// `sampleRate` must be one Opus encodes at: 8, 12, 16, 24 or 48 kHz.
    init(sampleRate: Double = 16_000, bitRate: Int = 24_000) {
        input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        opus = OggOpus.format(rate: sampleRate)
        converter = AVAudioConverter(from: input, to: opus)
        converter?.bitRate = bitRate
        frameBytes = Int(sampleRate) / 50 * 2
        scale = Int64(48_000 / sampleRate)
        // The encoder's lookahead: the decoder drops this much from the start.
        preSkip = Int(converter?.primeInfo.leadingFrames ?? 0) * Int(scale)
    }

    /// Any amount of PCM; returns the complete pages it makes (the first call's output starts
    /// with the OpusHead and OpusTags pages). Less than 20 ms waits for the next call.
    func encode(_ pcm: Data) -> Data {
        guard !finished else { return Data() }
        var out = header()
        pending.append(pcm)
        let whole = pending.count / frameBytes * frameBytes
        guard whole > 0 else { return out }
        let chunk = pending.prefix(whole)
        pending.removeFirst(whole)
        out.append(page(packets: run(chunk, last: false), last: false))
        return out
    }

    /// What is left, padded with silence, and the encoder's lookahead; the last page is marked
    /// end of stream. Nothing more is encoded after this.
    func finish() -> Data {
        guard !finished else { return Data() }
        var out = header()
        let packets = run(pending, last: true)
        pending = Data()
        finished = true
        out.append(page(packets: packets, last: true))
        return out
    }

    private func header() -> Data {
        guard !started else { return Data() }
        started = true
        var head = Data("OpusHead".utf8)
        head.append(contentsOf: [1, 1])
        head.appendLittleEndian(UInt16(preSkip))
        head.appendLittleEndian(UInt32(input.sampleRate))
        head.appendLittleEndian(UInt16(0))
        head.append(0)
        var tags = Data("OpusTags".utf8)
        let vendor = Data("Fish Pocket".utf8)
        tags.appendLittleEndian(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLittleEndian(UInt32(0))
        var out = writer.page(packets: [head], granule: 0, flags: OggWriter.begin)
        out.append(writer.page(packets: [tags], granule: 0, flags: 0))
        return out
    }

    /// Opus packets for `pcm` (whole 20 ms frames, or anything with `last`, which also flushes).
    private func run(_ pcm: Data, last: Bool) -> [Data] {
        guard let converter else { return [] }
        let frames = pcm.count / 2
        consumed += Int64(frames)
        var source: AVAudioPCMBuffer?
        if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)) {
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBytes { buffer.int16ChannelData![0].update(from: $0.bindMemory(to: Int16.self).baseAddress!, count: frames) }
            source = buffer
        }
        var packets: [Data] = []
        let capacity = AVAudioPacketCount(frames / (frameBytes / 2) + 2)
        let size = max(converter.maximumOutputPacketSize, 1_275)
        while true {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: capacity, maximumPacketSize: size)
            let status = converter.convert(to: out, error: nil) { _, state in
                if let given = source {
                    source = nil
                    state.pointee = .haveData
                    return given
                }
                state.pointee = last ? .endOfStream : .noDataNow
                return nil
            }
            if let descriptions = out.packetDescriptions {
                for index in 0..<Int(out.packetCount) {
                    let item = descriptions[index]
                    packets.append(Data(bytes: out.data + Int(item.mStartOffset), count: Int(item.mDataByteSize)))
                }
            }
            if status != .haveData { break }
        }
        return packets
    }

    private func page(packets: [Data], last: Bool) -> Data {
        guard !packets.isEmpty || last else { return Data() }
        let start = granule
        granule += Int64(packets.count) * 960
        // The end page says where the real audio stops, so the padding is cut off.
        let end = last ? min(granule, Int64(preSkip) + consumed * scale) : nil
        return writer.pages(packets: packets, granule: start, end: end)
    }
}

/// Volcengine's Ogg Opus speech (cut anywhere: a page can arrive in pieces) to mono 16-bit PCM
/// at `outputRate`, decoded at that rate. Skips the OpusHead and OpusTags packets and the
/// encoder's pre-skip, and cuts the padding off the end page; a new stream (another OpusHead)
/// starts over. Not thread-safe.
final class OggOpusDecoder {
    private let rate: Double
    private let output: AVAudioFormat
    private var decoder: AVAudioConverter?
    private var buffer = Data()
    private var packet = Data()
    /// Packets of the current stream: 0 before OpusHead, 1 before OpusTags, then audio.
    private var seen = 0
    /// The stream's pre-skip in 48 kHz samples, and samples (at `rate`) still to drop for it.
    private var preSkip = 0
    private var skip = 0
    /// Samples handed out for the current stream.
    private var played = 0

    /// `outputRate` must be one Opus decodes at: 8, 12, 16, 24 or 48 kHz.
    init(outputRate: Double = 24_000) {
        precondition(OggOpus.rates.contains(outputRate), "Opus decodes at 8, 12, 16, 24 or 48 kHz")
        rate = outputRate
        output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true)!
    }

    func decode(_ bytes: Data) -> Data {
        buffer.append(bytes)
        var pcm = Data()
        while let page = OggPage(buffer) {
            buffer = Data(buffer.dropFirst(page.skipped + page.size))
            // A packet is whole only if its pages came in one after another: after junk, or
            // when a page does not go on with the packet that was being put together (or goes
            // on with one whose start was lost), that packet is dropped.
            if page.skipped > 0 || !page.continued { packet = Data() }
            var broken = page.continued && packet.isEmpty
            var segment = page.bodyStart
            var sound = Data()
            for lace in page.laces {
                if !broken { packet.append(page.data[segment..<segment + lace]) }
                segment += lace
                guard lace < 255 else { continue }
                if !broken { sound.append(handle(packet)) }
                broken = false
                packet = Data()
            }
            played += sound.count / 2
            // The end page's position says where the speech stops; past it is padding.
            if page.last, seen == 2 {
                let length = Int(max(0, page.granule - Int64(preSkip))) * Int(rate) / 48_000
                let extra = min(max(0, played - length), sound.count / 2)
                sound.removeLast(extra * 2)
                played -= extra
            }
            pcm.append(sound)
        }
        if buffer.count > 1 << 20 { buffer = Data() }
        return pcm
    }

    private func handle(_ packet: Data) -> Data {
        if packet.starts(with: Data("OpusHead".utf8)), packet.count >= 19 {
            seen = 1
            preSkip = Int(packet[packet.startIndex + 10]) | Int(packet[packet.startIndex + 11]) << 8
            skip = preSkip * Int(rate) / 48_000
            played = 0
            decoder = AVAudioConverter(from: OggOpus.format(rate: rate), to: output)
            return Data()
        }
        switch seen {
        case 0: return Data()
        case 1: seen = 2; return Data()
        default: return play(packet)
        }
    }

    private func play(_ packet: Data) -> Data {
        guard let decoder else { return Data() }
        let frames = OggOpus.duration(packet) * Int(rate) / 48_000
        guard frames > 0 else { return Data() }
        let source = AVAudioCompressedBuffer(format: decoder.inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { source.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        source.byteLength = UInt32(packet.count)
        source.packetCount = 1
        source.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(frames), mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)) else { return Data() }
        var given = false
        _ = decoder.convert(to: out, error: nil) { _, state in
            guard !given else {
                state.pointee = .noDataNow
                return nil
            }
            given = true
            state.pointee = .haveData
            return source
        }
        let made = Int(out.frameLength)
        // The system's decoder drops the first 2.5 ms of a stream on its own: that counts
        // toward the pre-skip.
        skip = max(0, skip - (frames - made))
        let dropped = min(skip, made)
        skip -= dropped
        guard made > dropped, let samples = out.int16ChannelData?[0] else { return Data() }
        return Data(bytes: samples + dropped, count: (made - dropped) * 2)
    }
}

enum OggOpus {
    /// The rates Opus encodes and decodes at.
    static let rates: Set<Double> = [8_000, 12_000, 16_000, 24_000, 48_000]

    /// Mono Opus in 20 ms packets at `rate`.
    static func format(rate: Double) -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(rate / 50), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        return AVAudioFormat(streamDescription: &description)!
    }

    /// A packet's length in 48 kHz samples, from its TOC byte (RFC 6716 §3.1).
    static func duration(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0..<12: frame = [480, 960, 1_920, 2_880][config % 4]
        case 12..<16: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        let count: Int
        switch toc & 0x03 {
        case 0: count = 1
        case 1, 2: count = 2
        default: count = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3f) : 0
        }
        return frame * count
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting from zero.
    static func crc(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) ^ crcTable[Int(($0 >> 24) ^ UInt32($1))] }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n) << 24) { c, _ in c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
    }
}

/// Ogg pages of one logical stream.
private struct OggWriter {
    static let begin: UInt8 = 0x02
    static let end: UInt8 = 0x04
    static let continued: UInt8 = 0x01

    private let serial = UInt32.random(in: 0...UInt32.max)
    private var sequence: UInt32 = 0

    /// 20 ms `packets` after `granule` (48 kHz samples so far), on as many pages as their lacing
    /// needs (255 segments a page). With `end`, the last page ends the stream at that position.
    mutating func pages(packets: [Data], granule: Int64, end: Int64?) -> Data {
        var out = Data()
        var position = granule
        var group: [Data] = []
        var segments = 0
        for packet in packets {
            let need = packet.count / 255 + 1
            if segments + need > 255, !group.isEmpty {
                out.append(page(packets: group, granule: position, flags: 0))
                group = []
                segments = 0
            }
            group.append(packet)
            segments += need
            position += 960
        }
        out.append(page(packets: group, granule: end ?? position, flags: end == nil ? 0 : Self.end))
        return out
    }

    /// One page holding whole packets (each under 255 × 255 bytes).
    mutating func page(packets: [Data], granule: Int64, flags: UInt8) -> Data {
        var laces: [UInt8] = []
        for packet in packets {
            laces += Array(repeating: 255, count: packet.count / 255)
            laces.append(UInt8(packet.count % 255))
        }
        var page = Data("OggS".utf8)
        page.append(0)
        page.append(flags)
        page.appendLittleEndian(UInt64(bitPattern: granule))
        page.appendLittleEndian(serial)
        page.appendLittleEndian(sequence)
        page.appendLittleEndian(UInt32(0))
        page.append(UInt8(laces.count))
        page.append(contentsOf: laces)
        packets.forEach { page.append($0) }
        let crc = page.withUnsafeBytes { OggOpus.crc($0) }
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        sequence += 1
        return page
    }
}

/// The first whole page in `data` whose CRC checks out. `skipped` bytes of junk come before it.
private struct OggPage {
    let data: Data
    let skipped: Int
    let size: Int
    let continued: Bool
    /// The stream ends with this page.
    let last: Bool
    let granule: Int64
    let laces: [Int]
    /// Where the body starts in `data`.
    let bodyStart: Int

    init?(_ buffer: Data) {
        let data = buffer.startIndex == 0 ? buffer : Data(buffer)
        let capture = Data("OggS".utf8)
        var from = 0
        while true {
            guard let found = data.range(of: capture, in: from..<data.count) else { return nil }
            let start = found.lowerBound
            guard data.count >= start + 27 else { return nil }
            let count = Int(data[start + 26])
            guard data.count >= start + 27 + count else { return nil }
            let laces = data[start + 27..<start + 27 + count].map(Int.init)
            let size = 27 + count + laces.reduce(0, +)
            guard data.count >= start + size else { return nil }
            var check = Data(data[start..<start + size])
            check.replaceSubrange(22..<26, with: Data(count: 4))
            let stored = data[start + 22..<start + 26].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            if data[start + 4] == 0, check.withUnsafeBytes({ OggOpus.crc($0) }) == stored {
                self.data = data
                skipped = start
                self.size = size
                continued = data[start + 5] & OggWriter.continued != 0
                last = data[start + 5] & OggWriter.end != 0
                granule = data[start + 6..<start + 14].enumerated().reduce(Int64(0)) { $0 | Int64($1.element) << (8 * $1.offset) }
                self.laces = laces
                bodyStart = start + 27 + count
                return
            }
            // Not a page after all: look further on.
            from = start + 1
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
