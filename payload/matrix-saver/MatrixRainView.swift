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

    /// Shared frame rate: the saver's animationTimeInterval, and the rate the
    /// wallpaper's own timer in main.swift targets (halved on battery).
    ///
    /// 12 rather than 15: the rain is deliberately steppy, so a fifth fewer
    /// frames is nearly invisible while costing a fifth less CPU. Full-screen
    /// glyph stamping across two displays is the single most expensive thing
    /// this theme does.
    static let saverFPS: Double = 12.0

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

    /// Pixel density the layer and sprites are rasterized at: the display's
    /// native backing scale, so glyphs map 1:1 to device pixels on Retina
    /// panels. The wallpaper renders native too — occlusion gating, the
    /// pause-under-saver flag, and its sparser grid keep its measured cost
    /// negligible (~0.1% CPU over a day), so 1x rendering bought nothing
    /// but blur.
    private var renderScale: CGFloat = 1
    /// Size the current column grid was built for; lets setFrameSize rebuild
    /// only on a real change (legacyScreenSaver can hand the view a
    /// placeholder frame and resize it later, once per display).
    private var gridSize: NSSize = .zero

    private let cHead   = NSColor(srgbRed: 0.91, green: 1.00, blue: 0.91, alpha: 1)
    private let cBright = NSColor(srgbRed: 0.40, green: 1.00, blue: 0.53, alpha: 1)
    private let cMid    = NSColor(srgbRed: 0.00, green: 1.00, blue: 0.25, alpha: 1)
    private let cDim    = NSColor(srgbRed: 0.04, green: 0.42, blue: 0.13, alpha: 1)

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / Self.saverFPS
        configureLayer()
        buildGrid()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / Self.saverFPS
        configureLayer()
        buildGrid()
    }


    private func configureLayer() {
        wantsLayer = true
        layer?.drawsAsynchronously = true
        updateRenderScale()
    }

    private func updateRenderScale() {
        let s = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        guard s != renderScale || layer?.contentsScale != s else { return }
        renderScale = s
        layer?.contentsScale = s
        layer?.magnificationFilter = .nearest
        Self.glyphCache.removeAll()      // sprites are scale-specific
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderScale()              // display changed under us; re-match it
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderScale()              // backing scale is only knowable here
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != gridSize { buildGrid() }
    }

    private func buildGrid() {
        Self.glyphCache.removeAll()
        let pt: CGFloat = isPreview ? 7 : (Self.desktopMode ? 22 : 16)
        font = NSFont(name: "Menlo", size: pt)
            ?? NSFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        let m = ("ﾊ" as NSString).size(withAttributes: [.font: font])
        cellW = max(m.width, pt * 0.6)
        cellH = pt * 1.25
        // Overscan one cell past the top and bottom edges (columns already
        // overscan horizontally): integer truncation leaves a sub-cell strip
        // below the last row, and the burn-in drift shifts the lattice by up
        // to a full cell — cos(0)=1 means maximum upward shift at launch, so
        // without overscan the saver opens with a black band along the bottom.
        rows = max(1, Int(ceil(bounds.height / cellH)) + 3)
        let ncols = max(1, Int(bounds.width / cellW)) + 2
        columns = (0..<ncols).map { _ in makeColumn(initial: true) }
        gridSize = bounds.size
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
        if bounds.size != gridSize { buildGrid() }
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
                let y = bounds.height - CGFloat(r - 1) * cellH + shiftY
                if let s = sprite(col.glyphs[r % col.glyphs.count], tier) {
                    ctx.draw(s.img, in: CGRect(x: x, y: y, width: s.w, height: s.h))
                }
                r -= 1
            }
        }
    }

    // Pre-rasterized CGImage per glyph/tier, rendered at renderScale pixels but
    // stamped at point size, so glyphs stay crisp on any display density.
    // Stamping with CGContext.draw is far cheaper than NSImage.draw, which
    // re-resolves reps on every call.
    private func sprite(_ glyph: NSString, _ tier: Int) -> Sprite? {
        let key = "\(Int(font.pointSize))|\(tier)|\(renderScale)|\(glyph)"
        if let cached = Self.glyphCache[key] { return cached }
        let color = [cHead, cBright, cMid, cDim][tier]
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let sz = glyph.size(withAttributes: attrs)
        let w = max(1, Int(ceil(sz.width)))
        let h = max(1, Int(ceil(sz.height)))
        let pw = max(1, Int(ceil(CGFloat(w) * renderScale)))
        let ph = max(1, Int(ceil(CGFloat(h) * renderScale)))
        guard let cg = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.scaleBy(x: renderScale, y: renderScale)
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
