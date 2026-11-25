import SwiftUI

/// What dsh-image-gen's tools made, under their row in the conversation: the pictures at full
/// size (tap for the viewer, which saves, shares and marks them up), the provider and model
/// that made them, a placeholder while they are being made, and, when it failed, why, with
/// the way to the settings that fix it. The row above still opens the call's details.
struct ImageGenCard: View {
    let call: ToolCall
    let live: Bool
    @Environment(AppModel.self) private var app

    static let tools: Set<String> = ["generate_image", "generate_images", "edit_image"]
    static func handles(_ call: ToolCall) -> Bool { tools.contains(call.displayName) }

    /// Two to a row, small enough for the narrowest conversation column.
    private static let tile = CGSize(width: 140, height: 140)

    private var batch: Bool { call.displayName == "generate_images" }
    private var expected: Int { batch ? max(1, call.arguments["prompts"].array.count) : 1 }

    var body: some View {
        if !call.finished {
            // A call a finished turn never answered shows nothing here: its row says it stopped.
            if live { placeholder }
        } else if call.isError {
            if call.errorCode != "interrupted" { failure(call.result ?? "") }
        } else {
            results
        }
    }

    // MARK: Making

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expected == 1 {
                Palette.field
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .overlay { making }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                tiles(count: expected) { _ in Palette.field.overlay { ProgressView() } }
                Text("正在生成 \(expected) 张图片…").font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(call.displayName == "edit_image" ? "正在编辑图片" : "正在生成图片"))
    }

    private var making: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(call.displayName == "edit_image" ? "正在编辑图片…" : "正在生成图片…")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
        }
    }

    /// The asked-for shape, so the picture lands where its placeholder was.
    private var placeholderSize: CGSize {
        if let ratio = call.arguments["aspect_ratio"].string ?? call.arguments["size"].string {
            let parts = ratio.split(whereSeparator: { $0 == ":" || $0 == "x" }).compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { return ImageGroup.singleSize(CGSize(width: parts[0], height: parts[1])) }
        }
        return ImageGroup.singleSize(CGSize(width: 1, height: 1))
    }

    // MARK: Made

    @ViewBuilder
    private var results: some View {
        let images = call.resultImages.filter { $0.attachmentId != nil }
        VStack(alignment: .leading, spacing: 6) {
            if images.count == 1, let only = images.first {
                AttachmentThumb(attachment: only, size: ImageGroup.singleSize(only))
            } else if !images.isEmpty {
                tiles(count: images.count) { index in AttachmentThumb(attachment: images[index], size: Self.tile) }
            } else if call.meta["kind"].string == "dsh-image-gen-svg" {
                Label(call.meta["savedTo"].string.map { String(localized: "SVG 矢量图已保存到 \($0)") } ?? String(localized: "SVG 矢量图在调用详情里"), systemImage: "square.on.circle")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1) }
            ForEach(Array(failures.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(3)
            }
        }
    }

    /// 「Google Gemini · gemini-3.1-flash-image」: the first image's maker, as the plugin records it.
    /// An OpenAI-compatible channel goes by its own name (「Fish Pocket 账号（Seedream）」).
    private var caption: String? {
        let meta = batch ? call.meta["images"][0] : call.meta
        guard let raw = meta["provider"].string else { return nil }
        let provider = raw == ImageGenProvider.openaiCompat.rawValue && meta["channel"].string != nil
            ? ImageGenChannel.title(of: meta["channel"].string ?? "", in: app.settings.namespace(ImageGenModel.namespace)?["value"] ?? .null)
            : ImageGenProvider(rawValue: raw)?.title ?? raw
        let model = meta["model"].string ?? ""
        return model.isEmpty ? provider : "\(provider) · \(model)"
    }

    /// A batch reports the prompts that failed, one line each after its first.
    private var failures: [String] {
        guard batch, let text = call.result else { return [] }
        return text.split(separator: "\n").map(String.init).compactMap { line in
            guard let range = line.range(of: " — failed: ") else { return nil }
            return String(localized: "「\(String(line[..<range.lowerBound]))」没有生成：\(String(line[range.upperBound...]))")
        }
    }

    private func tiles<Tile: View>(count: Int, @ViewBuilder tile: @escaping (Int) -> Tile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: count, by: 2)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(start..<min(start + 2, count), id: \.self) { index in
                        tile(index)
                            .frame(width: Self.tile.width, height: Self.tile.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: Failed

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(call.displayName == "edit_image" ? "图片没有编辑成功" : "图片没有生成成功", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            if !message.isEmpty {
                Text(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(4)
            }
            Button("生图设置") { app.requestCredentials(.imageGen) }
                .buttonStyle(.capsule(.outline, height: 36, fill: false))
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
