import PencilKit
import SwiftUI

/// 标注: drawing on a picture from the conversation with the system's pencil tools (the ones
/// Notes uses), a finger as well as an Apple Pencil. 完成 hands back the marked copy, which goes
/// into the draft like any picked image.
struct MarkupCanvas: View {
    let picture: UIImage
    let done: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var drawn = false
    @State private var confirmingDiscard = false
    /// The paper's size, kept through the layouts a closing page passes through.
    @State private var paper: CGSize = .zero
    /// What 完成 made, shown in the canvas's place while the page closes: laid out again in a
    /// collapsing container, the canvas re-renders its strokes at a size past the GPU's limit
    /// and the system ends the app.
    @State private var result: UIImage?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = paper
                ZStack {
                    Image(uiImage: result ?? picture).resizable().frame(width: size.width, height: size.height)
                    if result == nil, size.width > 0 {
                        PencilCanvas(canvas: canvas) { drawn = !canvas.drawing.strokes.isEmpty }
                            .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: proxy.size, initial: true) { _, space in
                    // A page sliding away collapses its container: those layouts keep the paper as it was.
                    guard result == nil, space.width > 100, space.height > 100 else { return }
                    paper = paperSize(in: space)
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle("标注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if drawn { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { finish() }.disabled(!drawn)
                }
                ToolbarItemGroup(placement: .principal) {
                    HStack(spacing: 18) {
                        Button { canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .accessibilityLabel("撤销")
                        Button { canvas.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                            .accessibilityLabel("重做")
                        Button { canvas.drawing = PKDrawing(); drawn = false } label: { Image(systemName: "trash") }
                            .accessibilityLabel("清空")
                            .disabled(!drawn)
                    }
                }
            }
            .confirmationDialog("放弃这次画的内容？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { dismiss() }
            }
        }
        .interactiveDismissDisabled(drawn)
    }

    /// The picture's shape fitted into the space, which ends above the tool palette (the system
    /// docks it like a keyboard).
    private func paperSize(in space: CGSize) -> CGSize {
        let room = CGSize(width: max(1, space.width - 24), height: max(1, space.height - 24))
        guard picture.size.width > 0, picture.size.height > 0 else { return room }
        let scale = min(room.width / picture.size.width, room.height / picture.size.height)
        return CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
    }

    private func finish() {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        // The marked copy only says where: 2048 pixels on the long side are plenty, and keep the
        // strokes' rendering well inside what the GPU takes.
        let full = CGSize(width: picture.size.width * picture.scale, height: picture.size.height * picture.scale)
        let fit = min(1, 2048 / max(full.width, full.height, 1))
        let pixels = CGSize(width: (full.width * fit).rounded(), height: (full.height * fit).rounded())
        var marks = UIImage()
        // Drawn in the light: the system shows dark ink light in the dark, and the marks go on the picture as drawn.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            marks = canvas.drawing.image(from: bounds, scale: pixels.width / bounds.width)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let marked = UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            picture.draw(in: CGRect(origin: .zero, size: pixels))
            marks.draw(in: CGRect(origin: .zero, size: pixels))
        }
        result = marked
        done(marked)
        dismiss()
    }
}

/// `PKCanvasView` over the picture, with the system tool palette, which shows while the canvas
/// is first responder. A red pen to start with: it stands out on most pictures.
private struct PencilCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let changed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 8)
        canvas.delegate = context.coordinator
        let picker = context.coordinator.picker
        picker.overrideUserInterfaceStyle = .light
        picker.selectedTool = canvas.tool
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: Coordinator) {
        coordinator.picker.setVisible(false, forFirstResponder: uiView)
        coordinator.picker.removeObserver(uiView)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let picker = PKToolPicker()
        let changed: () -> Void
        init(changed: @escaping () -> Void) { self.changed = changed }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed() }
    }
}
