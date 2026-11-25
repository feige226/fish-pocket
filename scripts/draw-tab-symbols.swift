// Draws the tab bar's own SF Symbols into app/DshIOS/Assets.xcassets/Symbols:
// - 会话's speech bubble, `fp.message` and `fp.message.fill`. The system's own `message` may only
//   stand for Apple's Messages app, so this is our own drawing in the same spirit.
// - Bot's character, `fp.bot` and `fp.bot.fill`: the outline of the default Bot (`gumdrop` in
//   BotCharacter.swift) with its two eyes, so the tab looks like the Bots it opens. SF Symbols has no
//   robot, and the smiley it had said nothing about Bots.
//
//   swift scripts/draw-tab-symbols.swift app/DshIOS/Assets.xcassets/Symbols
//
// It writes a full SF Symbols template (template v.3.0): all nine weights at the three scales, so the
// symbol follows the text's weight, Dynamic Type and image scale like a system one does.
//
import Foundation
import CoreGraphics

// One design, stroked at each weight: a skeleton (the line down the middle of the stroke) is drawn
// once, then stroked at the weight's thickness. The filled form is the skeleton's area plus the
// outer half of the same stroke, so outline and fill line up at every weight.

let weights = ["Ultralight","Thin","Light","Regular","Medium","Semibold","Bold","Heavy","Black"]
let colX: [Double] = [559.711, 856.422, 1153.13, 1449.84, 1746.56, 2043.27, 2339.98, 2636.69, 2933.4]
let baselines: [String: Double] = ["S": 696, "M": 1126, "L": 1556]
// Stroke thickness per weight at each scale, measured from the system's own symbols at 100 pt.
let strokes: [String: [Double]] = [
  "S": [2.25, 3.25, 5.5, 7.0, 8.25, 9.25, 10.5, 12.25, 13.75],
  "M": [2.3, 3.5, 6.0, 8.0, 9.25, 10.75, 12.25, 14.75, 16.75],
  "L": [2.5, 4.0, 6.5, 8.75, 10.75, 12.0, 14.0, 17.0, 19.5],
]
// The skeleton grows a little with weight, as the system's symbols do.
let growth: [Double] = [0.988, 0.993, 0.998, 1.0, 1.012, 1.014, 1.024, 1.036, 1.046]
let scaleOf: [String: Double] = ["S": 0.80, "M": 1.0, "L": 1.28]

// Skeletons at Regular, medium scale. y up, baseline 0, cap height 70.459.
let A0 = 53.0, B0 = 41.5
func bubble() -> CGMutablePath {
  let p = CGMutablePath()
  let cy = 0.0
  func pt(_ deg: Double) -> CGPoint { let r = deg * .pi / 180; return CGPoint(x: A0 * cos(r), y: cy + B0 * sin(r)) }
  func tan(_ deg: Double) -> CGPoint { let r = deg * .pi / 180; let v = CGPoint(x: -A0 * sin(r), y: B0 * cos(r)); let l = hypot(v.x, v.y); return CGPoint(x: v.x / l, y: v.y / l) }
  let t1 = 212.0, t2 = 250.0
  let p1 = pt(t1), p2 = pt(t2)
  let tip = CGPoint(x: -A0 * 0.88, y: -B0 - 5.5)
  p.move(to: p2)
  // the body: from where the tail rejoins at the bottom, round the right, the top and the left.
  p.addArc(center: .zero, radius: 1, startAngle: t2 * .pi / 180, endAngle: (t1 + 360) * .pi / 180, clockwise: false,
           transform: CGAffineTransform(translationX: 0, y: cy).scaledBy(x: A0, y: B0))
  // down the left side, drawing in a little, then out into the tip
  let d1 = tan(t1)
  p.addCurve(to: tip,
             control1: CGPoint(x: p1.x + d1.x * 9, y: p1.y + d1.y * 9),
             control2: CGPoint(x: tip.x + 4.0, y: tip.y + 5.0))
  // from the tip back along the bottom into the body, meeting it smoothly
  let d2 = tan(t2)
  p.addCurve(to: p2,
             control1: CGPoint(x: tip.x + 6.0, y: tip.y - 0.5),
             control2: CGPoint(x: p2.x - d2.x * 8, y: p2.y - d2.y * 8))
  p.closeSubpath()
  return p
}

// The gumdrop: a round top on a flat-bottomed body with rounded corners, 76 across in BotCharacter's
// 100-grid, drawn here a little larger to sit as big as the system's round symbols.
let botScale = 1.13
func bot() -> CGMutablePath {
  let k = botScale, r = 38.0 * k, c = 13.0 * k
  let p = CGMutablePath()
  p.move(to: CGPoint(x: -r, y: 0))
  p.addArc(center: .zero, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
  p.addLine(to: CGPoint(x: r, y: -r + c))
  p.addArc(tangent1End: CGPoint(x: r, y: -r), tangent2End: CGPoint(x: r - c, y: -r), radius: c)
  p.addLine(to: CGPoint(x: -r + c, y: -r))
  p.addArc(tangent1End: CGPoint(x: -r, y: -r), tangent2End: CGPoint(x: -r, y: -r + c), radius: c)
  p.closeSubpath()
  return p
}
// Its eyes, two upright capsules a little below the middle. They thicken with the weight like the
// line does, so a thin outline does not get heavy eyes.
func botEyes(stroke: Double) -> CGPath {
  let k = botScale, w = 4.2 + stroke * 0.6, h = w * 1.75, gap = 21.0 * k, y = -2.0 * k
  let p = CGMutablePath()
  for x in [-gap / 2, gap / 2] {
    p.addRoundedRect(in: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), cornerWidth: w / 2, cornerHeight: w / 2)
  }
  return p
}

struct Design { let name: String; let skeleton: () -> CGMutablePath; let eyes: ((Double) -> CGPath)?; let lift: Double }
let designs = [
  // The bubble's tail hangs below, so its ink sits a little above the cap height's middle.
  Design(name: "fp.message", skeleton: bubble, eyes: nil, lift: 2.0),
  Design(name: "fp.bot", skeleton: bot, eyes: botEyes, lift: 0),
]

func svgPath(_ path: CGPath, dx: Double, dy: Double) -> String {
  var d = ""
  func q(_ p: CGPoint) -> String { "\(String(format: "%.3f", Double(p.x) - dx)) \(String(format: "%.3f", -(Double(p.y)) + dy))" }
  path.applyWithBlock { e in
    let pts = e.pointee.points
    switch e.pointee.type {
    case .moveToPoint: d += "M\(q(pts[0]))"
    case .addLineToPoint: d += "L\(q(pts[0]))"
    case .addQuadCurveToPoint: d += "Q\(q(pts[0])) \(q(pts[1]))"
    case .addCurveToPoint: d += "C\(q(pts[0])) \(q(pts[1])) \(q(pts[2]))"
    case .closeSubpath: d += "Z"
    @unknown default: break
    }
  }
  return d
}

// Eyes, where a design has them, are solid in the outline and cut out of the filled form.
func glyph(_ design: Design, fill: Bool, weight w: Int, scale s: String) -> CGPath {
  let k = scaleOf[s]! * growth[w]
  var t = CGAffineTransform(scaleX: k, y: k)
  let sk = design.skeleton().copy(using: &t)!
  let width = strokes[s]![w]
  let stroked = sk.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
  let shape = fill ? sk.union(stroked, using: .winding) : stroked.normalized(using: .winding)
  guard let eyes = design.eyes?(width / scaleOf[s]!).copy(using: &t) else { return shape }
  return fill ? shape.subtracting(eyes, using: .winding) : shape.union(eyes, using: .winding)
}

func template(_ design: Design, fill: Bool, name: String) -> String {
  var guides = "", symbols = ""
  for (s, base) in baselines.sorted(by: { $0.value < $1.value }) {
    guides += """
      <line id="Baseline-\(s)" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(base)" y2="\(base)"/>
      <line id="Capline-\(s)" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(String(format: "%.3f", base - 70.459))" y2="\(String(format: "%.3f", base - 70.459))"/>

    """
    for (i, wName) in weights.enumerated() {
      let g = glyph(design, fill: fill, weight: i, scale: s)
      let b = g.boundingBoxOfPath
      // Centred on the column, and on the cap height's middle (lifted where a tail hangs below).
      let left = colX[i] - Double(b.width) / 2
      let midY = 70.459 / 2 + design.lift * scaleOf[s]!
      let dy = midY - Double(b.midY) // shift up so the ink's middle sits there
      // path coordinates: x from 0 at the left margin, y negative upward from the baseline
      let d = svgPath(g, dx: Double(b.minX), dy: -dy)
      guides += """
        <line id="left-margin-\(wName)-\(s)" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(String(format: "%.3f", left))" x2="\(String(format: "%.3f", left))" y1="\(base - 95)" y2="\(base + 24)"/>
        <line id="right-margin-\(wName)-\(s)" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(String(format: "%.3f", left + Double(b.width)))" x2="\(String(format: "%.3f", left + Double(b.width)))" y1="\(base - 95)" y2="\(base + 24)"/>

      """
      symbols += """
        <g id="\(wName)-\(s)" transform="matrix(1 0 0 1 \(String(format: "%.3f", left)) \(base))">
         <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="\(d)"/>
        </g>

      """
    }
  }
  return """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
  <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
   <!--glyph: "\(name)", point size: 100.0, template writer version: "fish-pocket"-->
   <style>.SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
  </style>
   <g id="Notes">
    <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
    <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
    <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">\(name)</text>
   </g>
   <g id="Guides">
  \(guides) </g>
   <g id="Symbols">
  \(symbols) </g>
  </svg>

  """
}

guard CommandLine.arguments.count == 2 else {
  print("usage: swift scripts/draw-tab-symbols.swift <asset catalog folder>"); exit(1)
}
let out = CommandLine.arguments[1]
for design in designs { for fill in [false, true] {
  let name = fill ? "\(design.name).fill" : design.name
  let dir = "\(out)/\(name).symbolset"
  try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  try! template(design, fill: fill, name: name).write(toFile: "\(dir)/\(name).svg", atomically: true, encoding: .utf8)
  try! """
  {
    "info" : { "author" : "xcode", "version" : 1 },
    "symbols" : [ { "filename" : "\(name).svg", "idiom" : "universal" } ]
  }

  """.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
}}
