import Cocoa
import ScreenSaver

@objc(MatrixRainView)
final class MatrixRainView: ScreenSaverView {

    private struct Column {
        var head: Double
        var speed: Double
        var length: Int
        var glyphs: [NSString]
    }

    private static let pool: [NSString] = {
        var g: [NSString] = []
        for c in 0xFF66...0xFF9D {                      // half-width katakana
            if let u = Unicode.Scalar(c) { g.append(String(Character(u)) as NSString) }
        }
        g += "0123456789:.=*+-<>|".map { String($0) as NSString }
        return g
    }()

    private var columns: [Column] = []
    private var cellW: CGFloat = 12
    private var cellH: CGFloat = 16
    private var rows: Int = 0
    /// Desktop mode trades density for CPU: larger cells (fewer blits per frame)
    /// and sparser columns. The screensaver keeps the dense look.
    @objc static var desktopMode = false
    private struct Sprite { let img: CGImage; let w: CGFloat; let h: CGFloat }
    private static var glyphCache: [String: Sprite] = [:]
    private var tick: Double = 0        // drives slow sub-cell drift (burn-in mitigation)
    private var font = NSFont(name: "Menlo", size: 16)
        ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)

    private let cHead   = NSColor(srgbRed: 0.91, green: 1.00, blue: 0.91, alpha: 1)
    private let cBright = NSColor(srgbRed: 0.40, green: 1.00, blue: 0.53, alpha: 1)
    private let cMid    = NSColor(srgbRed: 0.00, green: 1.00, blue: 0.25, alpha: 1)
    private let cDim    = NSColor(srgbRed: 0.04, green: 0.42, blue: 0.13, alpha: 1)

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 15.0
        configureLayer()
        buildGrid()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 15.0
        configureLayer()
        buildGrid()
    }


    private func configureLayer() {
        wantsLayer = true
        layer?.contentsScale = 1.0
        layer?.magnificationFilter = .nearest
        layer?.drawsAsynchronously = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = 1.0        // resist the window's 2x backing scale
    }

    private func buildGrid() {
        Self.glyphCache.removeAll()
        let pt: CGFloat = isPreview ? 7 : (Self.desktopMode ? 22 : 16)
        font = NSFont(name: "Menlo", size: pt)
            ?? NSFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        let m = ("ﾊ" as NSString).size(withAttributes: [.font: font])
        cellW = max(m.width, pt * 0.6)
        cellH = pt * 1.25
        rows = max(1, Int(bounds.height / cellH))
        let ncols = max(1, Int(bounds.width / cellW)) + 2
        columns = (0..<ncols).map { _ in makeColumn(initial: true) }
    }

    private func makeColumn(initial: Bool) -> Column {
        // On the desktop, start many columns far above the viewport so roughly a
        // third of them are dormant at any moment.
        let gap = Self.desktopMode ? Double.random(in: -140 ... -1)
                                   : Double.random(in: -20 ... -1)
        return Column(
            head: initial ? Double.random(in: 0...Double(rows) * 1.3) : gap,
            speed: Double.random(in: 0.25...1.1),
            length: Int.random(in: max(4, rows / 5)...max(6, rows)),
            glyphs: (0...(rows + 2)).map { _ in Self.pool.randomElement()! }
        )
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        buildGrid()
    }

    override func animateOneFrame() {
        // Desktop mode only: skip frames while covered. Never gate the saver on
        // occlusion — legacyScreenSaver.appex hosts the view in an offscreen
        // proxy window whose occlusionState never reads visible.
        if Self.desktopMode, let w = window,
           !(w.isVisible && w.occlusionState.contains(.visible)) { return }
        tick += 1
        for i in columns.indices {
            columns[i].head += columns[i].speed
            if Double.random(in: 0...1) < 0.35 {          // shimmer mid-fall
                let j = Int.random(in: 0..<columns[i].glyphs.count)
                columns[i].glyphs[j] = Self.pool.randomElement()!
            }
            if columns[i].head - Double(columns[i].length) > Double(rows) {
                columns[i] = makeColumn(initial: false)
            }
        }
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor.black)
        ctx.fill(bounds)
        ctx.interpolationQuality = .none    // sprites are stamped 1:1
        // Slow, irrational-period drift: the glyph lattice never settles on one
        // pixel alignment, so no column can etch a fixed vertical band.
        let shiftX = CGFloat(sin(tick * 0.00090)) * cellW
        let shiftY = CGFloat(cos(tick * 0.00061)) * cellH
        for (ci, col) in columns.enumerated() {
            let x = CGFloat(ci - 1) * cellW + shiftX
            let top = Int(col.head)
            var r = min(top, rows - 1)
            let bottom = max(0, top - col.length)
            while r >= bottom {
                let d = col.head - Double(r)
                let tier: Int
                if d < 1 { tier = 0 }
                else if d < 3 { tier = 1 }
                else if d < Double(col.length) * 0.55 { tier = 2 }
                else { tier = 3 }
                let y = bounds.height - CGFloat(r + 1) * cellH + shiftY
                if let s = sprite(col.glyphs[r % col.glyphs.count], tier) {
                    ctx.draw(s.img, in: CGRect(x: x, y: y, width: s.w, height: s.h))
                }
                r -= 1
            }
        }
    }

    // Pre-rasterized CGImage per glyph/tier; stamping these with CGContext.draw
    // is far cheaper than NSImage.draw, which re-resolves reps on every call.
    private func sprite(_ glyph: NSString, _ tier: Int) -> Sprite? {
        let key = "\(Int(font.pointSize))|\(tier)|\(glyph)"
        if let cached = Self.glyphCache[key] { return cached }
        let color = [cHead, cBright, cMid, cDim][tier]
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = glyph.size(withAttributes: attrs)
        let w = max(1, Int(ceil(sz.width)))
        let h = max(1, Int(ceil(sz.height)))
        guard let cg = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        glyph.draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = cg.makeImage() else { return nil }
        let s = Sprite(img: img, w: CGFloat(w), h: CGFloat(h))
        Self.glyphCache[key] = s
        return s
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
