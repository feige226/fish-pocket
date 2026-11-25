import AVFoundation
import os

/// The call's speaker, played the way a browser's audio context plays: 24 kHz mono samples are
/// placed at positions on its own clock, which counts the samples it has rendered. A position is
/// exact to the sample, so what was placed there is exactly what played there, and the echo
/// canceller's reference can say so. Between pieces it plays silence; the clock runs whenever the
/// engine does.
final class CallSpeaker: @unchecked Sendable {
    static let rate = 24_000
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
    let node: AVAudioSourceNode
    private let state: State

    init() {
        let state = State()
        self.state = state
        node = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            state.render(Int(frameCount), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
    }

    /// The samples rendered so far.
    var clock: Int { state.lock.withLockUnchecked { state.rendered } }

    /// Places `samples` at `position`, or, if that has come too close, at the earliest place a
    /// render cycle ahead. Returns where they went.
    func place(_ samples: [Float], notBefore position: Int) -> Int {
        state.lock.withLockUnchecked {
            let start = max(position, state.rendered + State.margin)
            let count = min(samples.count, State.capacity - (start - state.rendered))
            for index in 0..<max(count, 0) {
                state.ring[(start + index) % State.capacity] = samples[index]
            }
            state.placedEnd = max(state.placedEnd, start + samples.count)
            return start
        }
    }

    /// Silences everything placed that has not played yet; returns the position it stops at.
    func cut() -> Int {
        state.lock.withLockUnchecked {
            for position in state.rendered..<max(state.rendered, state.placedEnd) {
                state.ring[position % State.capacity] = 0
            }
            state.placedEnd = state.rendered
            return state.rendered
        }
    }

    /// The RMS of what rendered since the last call; nil if nothing did.
    func takeRMS() -> Float? {
        state.lock.withLockUnchecked {
            defer { state.energy = 0; state.energyCount = 0 }
            guard state.energyCount > 0 else { return nil }
            return (state.energy / Float(state.energyCount)).squareRoot()
        }
    }

    /// Shared with the render thread, under the lock. A ring four seconds long holds what is
    /// placed; rendering reads it at the clock and leaves silence behind.
    private final class State: @unchecked Sendable {
        static let capacity = CallSpeaker.rate * 4
        /// How far ahead of the clock a piece is placed at the soonest: past the cycle being rendered.
        static let margin = CallSpeaker.rate / 50
        let lock = OSAllocatedUnfairLock()
        let ring: UnsafeMutablePointer<Float>
        var rendered = 0
        var placedEnd = 0
        var energy: Float = 0
        var energyCount = 0

        init() {
            ring = .allocate(capacity: Self.capacity)
            ring.initialize(repeating: 0, count: Self.capacity)
        }

        deinit { ring.deallocate() }

        func render(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            lock.withLockUnchecked {
                for index in 0..<frames {
                    let slot = (rendered + index) % Self.capacity
                    let value = ring[slot]
                    ring[slot] = 0
                    first[index] = value
                    energy += value * value
                }
                rendered += frames
                energyCount += frames
            }
            for buffer in buffers.dropFirst() {
                buffer.mData?.copyMemory(from: first, byteCount: frames * MemoryLayout<Float>.size)
            }
        }
    }
}
