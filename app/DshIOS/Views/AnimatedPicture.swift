import Accessibility
import ImageIO
import SwiftUI
import UIKit

/// Animated GIF (and animated WebP, APNG) in the conversation. `UIImage(data:)` and the
/// thumbnail decoders keep only the first frame, so pictures go through `decode` first: an
/// animation comes back as an animated `UIImage` (`images` set), anything else as nil and is
/// decoded as a still the way it was before. `Picture` shows either kind.
enum AnimatedPicture {
    /// All frames are decoded up front; past this many bytes they are drawn smaller instead.
    private static let budget = 40 << 20
    private static let maxFrames = 300

    nonisolated static func decode(_ data: Data, longEdge: Int = 1024) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, longEdge: longEdge)
    }

    nonisolated static func decode(_ url: URL, longEdge: Int = 1024) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, longEdge: longEdge)
    }

    /// The picture in `data`, animated or still: what an attachment shows.
    nonisolated static func picture(_ data: Data) -> UIImage? {
        decode(data) ?? UIImage(data: data)
    }

    /// Bytes the frames of an animated picture hold, for cache costs; 0 for a still.
    static func cost(_ image: UIImage) -> Int {
        guard let frames = image.images, let first = frames.first?.cgImage else { return 0 }
        return first.bytesPerRow * first.height * Set(frames.map { ObjectIdentifier($0) }).count
    }

    private nonisolated static func decode(_ source: CGImageSource, longEdge: Int) -> UIImage? {
        let count = CGImageSourceGetCount(source)
        // More than one frame with frame delays: a multi-page TIFF or a HEIC burst has none.
        guard count > 1, delay(source, 0) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let frames = min(count, maxFrames)
        let long = Double(max(width, height))
        let fitBudget = (Double(budget) / Double(frames * 4 * width * height)).squareRoot()
        let edge = max(1, Int((long * min(1, Double(longEdge) / long, fitBudget)).rounded(.down)))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
        ] as CFDictionary

        var images: [UIImage] = []
        var delays: [Int] = []
        for index in 0..<frames {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            images.append(UIImage(cgImage: frame))
            delays.append(delay(source, index) ?? 10)
        }
        guard images.count > 1 else { return nil }

        // A UIImage animation shows every frame for as long as the others: each frame repeats
        // to follow its own delay, in steps of the largest delay that divides them all.
        let total = delays.reduce(0, +)
        let step = delays.reduce(0) { gcd($0, $1) }
        var timeline: [UIImage] = []
        if total / step <= 2000 {
            for (image, delay) in zip(images, delays) { timeline += Array(repeating: image, count: delay / step) }
        } else {
            timeline = images
        }
        return UIImage.animatedImage(with: timeline, duration: Double(total) / 100)
    }

    /// The frame's delay in hundredths of a second, as browsers time it: very short delays
    /// (0 or 1, meant as "as fast as possible") play at 0.1 s. Nil when the format has none.
    private nonisolated static func delay(_ source: CGImageSource, _ index: Int) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        let kinds: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in kinds {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let seconds = (values[unclamped] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? values[clamped] as? Double ?? 0
            let hundredths = Int((seconds * 100).rounded())
            return hundredths <= 1 ? 10 : hundredths
        }
        return nil
    }

    private nonisolated static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

extension UIImage {
    /// The first frame of an animated picture, else the picture: for drawing on and sharing.
    var still: UIImage { images?.first ?? self }
}

/// A decoded picture filling (cropped) or fitting the space it is given. An animated one plays,
/// unless 自动播放动态图像 is off in the system's accessibility settings.
struct Picture: View {
    let image: UIImage
    var contentMode: ContentMode = .fill

    var body: some View {
        if image.images != nil {
            // Taps and gestures land on the SwiftUI shape; the UIKit view only draws. Filling, it
            // takes the whole space and crops itself; fitting, the shape is the picture's.
            Group {
                if contentMode == .fit { Color.clear.aspectRatio(image.size, contentMode: .fit) } else { Color.clear }
            }
            .contentShape(Rectangle())
            .overlay { AnimatedImageView(image: image, fill: contentMode == .fill).allowsHitTesting(false) }
        } else {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        }
    }
}

private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    let fill: Bool

    func makeUIView(context: Context) -> PlayingImageView {
        let view = PlayingImageView(frame: .zero)
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: PlayingImageView, context: Context) {
        view.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.picture = image
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayingImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: image.size)
    }

    final class PlayingImageView: UIImageView {
        var picture: UIImage? {
            didSet { if picture !== oldValue { show() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(show), name: Self.settingChanged, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func show() {
            image = Self.plays ? picture : picture?.still
        }

        private static var plays: Bool {
            if #available(iOS 18, *) { return AccessibilitySettings.animatedImagesEnabled }
            return AXAnimatedImagesEnabled()
        }

        private static var settingChanged: Notification.Name {
            if #available(iOS 18, *) { return AccessibilitySettings.animatedImagesEnabledDidChangeNotification }
            return .AXAnimatedImagesEnabledDidChange
        }
    }
}

/// The engine keeps a still of every image it stores (DSH re-encodes a GIF as its first frame),
/// so the animated original a message went out with is kept here under the stored attachment's
/// id, and the bubble plays that. In Caches: if the system clears them, the bubble shows the
/// engine's still, as before.
enum SentAnimations {
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sent-animations", isDirectory: true)

    /// At send, while the picked bytes are still on disk; anything but an animation is skipped.
    static func keep(_ file: URL, for attachmentId: String) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 1 else { return }
        let copy = place(attachmentId)
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: file, to: copy)
    }

    static func data(for attachmentId: String) -> Data? {
        try? Data(contentsOf: place(attachmentId))
    }

    private static func place(_ attachmentId: String) -> URL {
        folder.appendingPathComponent(attachmentId.replacingOccurrences(of: "/", with: "_"))
    }
}
