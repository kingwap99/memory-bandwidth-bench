import AppKit

let S = 1024.0

func cg(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r / 255), green: CGFloat(g / 255), blue: CGFloat(b / 255), alpha: CGFloat(a))
}
func newCtx() -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func clipSquircle(_ ctx: CGContext) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S), cornerWidth: 205, cornerHeight: 205, transform: nil))
    ctx.clip()
}
func linGrad(_ ctx: CGContext, _ c1: CGColor, _ c2: CGColor, _ s: CGPoint, _ e: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: s, end: e, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func gradBar(_ ctx: CGContext, _ rect: CGRect, _ c1: CGColor, _ c2: CGColor, _ glow: CGColor?) {
    ctx.saveGState()
    if let glow = glow { ctx.setShadow(offset: .zero, blur: 26, color: glow) }
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    linGrad(ctx, c1, c2, CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY))
    ctx.restoreGState()
}
func savePNG(_ ctx: CGContext, _ path: String) {
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("saved " + path)
}
func capsule(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ w: Double, _ color: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(CGFloat(w))
    ctx.setLineCap(.round)
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawA(_ ctx: CGContext) {
    clipSquircle(ctx)
    linGrad(ctx, cg(16, 24, 38), cg(9, 13, 22), CGPoint(x: 0, y: S), CGPoint(x: 0, y: 0))
    ctx.setStrokeColor(cg(255, 255, 255, 0.035))
    ctx.setLineWidth(2)
    var x = 64.0
    while x < S {
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: S))
        ctx.move(to: CGPoint(x: 0, y: x)); ctx.addLine(to: CGPoint(x: S, y: x))
        x += 64
    }
    ctx.strokePath()
    let chip = CGRect(x: 292, y: 292, width: 440, height: 440)
    var i = 0
    while i < 6 {
        let p = 328.0 + Double(i) * 72.0
        capsule(ctx, CGPoint(x: chip.minX - 92, y: p), CGPoint(x: chip.minX + 4, y: p), 24, cg(201, 138, 75))
        capsule(ctx, CGPoint(x: chip.maxX - 4, y: p), CGPoint(x: chip.maxX + 92, y: p), 24, cg(201, 138, 75))
        capsule(ctx, CGPoint(x: p, y: chip.minY - 92), CGPoint(x: p, y: chip.minY + 4), 24, cg(201, 138, 75))
        capsule(ctx, CGPoint(x: p, y: chip.maxY - 4), CGPoint(x: p, y: chip.maxY + 92), 24, cg(201, 138, 75))
        i += 1
    }
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 40, color: cg(0, 0, 0, 0.5))
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(cg(22, 32, 47))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: cg(0, 0, 0, 0))
    ctx.setStrokeColor(cg(62, 81, 112))
    ctx.setLineWidth(8)
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.strokePath()
    ctx.setFillColor(cg(91, 107, 133))
    ctx.fillEllipse(in: CGRect(x: 322, y: 690, width: 24, height: 24))
    let heights = [110.0, 170.0, 230.0, 290.0, 350.0]
    var b = 0
    while b < 5 {
        let bx = 340.0 + Double(b) * 72.0
        let h = heights[b]
        gradBar(ctx, CGRect(x: bx, y: 360, width: 44, height: h), cg(59, 130, 246), cg(43, 217, 194), cg(43, 217, 194, 0.55))
        b += 1
    }
}

func drawB(_ ctx: CGContext) {
    clipSquircle(ctx)
    linGrad(ctx, cg(248, 249, 251), cg(226, 230, 238), CGPoint(x: 0, y: S), CGPoint(x: 0, y: 0))
    let chip = CGRect(x: 236, y: 236, width: 552, height: 552)
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 36, color: cg(30, 60, 120, 0.18))
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.setFillColor(cg(255, 255, 255))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: cg(0, 0, 0, 0))
    ctx.setStrokeColor(cg(210, 216, 226))
    ctx.setLineWidth(6)
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.strokePath()
    var i = 0
    while i < 5 {
        let p = 320.0 + Double(i) * 96.0
        capsule(ctx, CGPoint(x: chip.minX - 84, y: p), CGPoint(x: chip.minX + 6, y: p), 26, cg(170, 180, 196))
        capsule(ctx, CGPoint(x: chip.maxX - 6, y: p), CGPoint(x: chip.maxX + 84, y: p), 26, cg(170, 180, 196))
        i += 1
    }
    let heights = [120.0, 190.0, 260.0, 330.0]
    var b = 0
    while b < 4 {
        let bx = 322.0 + Double(b) * 104.0
        let h = heights[b]
        let rect = CGRect(x: bx, y: 340, width: 60, height: h)
        if b == 3 {
            ctx.setFillColor(cg(255, 149, 0))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.fillPath()
        } else {
            gradBar(ctx, rect, cg(10, 132, 255), cg(88, 176, 255), nil)
        }
        b += 1
    }
    ctx.setFillColor(cg(10, 132, 255))
    ctx.fillEllipse(in: CGRect(x: 288, y: 700, width: 22, height: 22))
}

func drawC(_ ctx: CGContext) {
    clipSquircle(ctx)
    linGrad(ctx, cg(16, 185, 129), cg(79, 70, 229), CGPoint(x: 0, y: S), CGPoint(x: S, y: 0))
    ctx.saveGState()
    ctx.setStrokeColor(cg(255, 255, 255, 0.16))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    var k = 0
    while k < 3 {
        let y = 760.0 - Double(k) * 260.0
        ctx.move(to: CGPoint(x: 120, y: y))
        ctx.addLine(to: CGPoint(x: 904, y: y + 120))
        k += 1
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 48, color: cg(0, 0, 0, 0.35))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 180, y: 330, width: 664, height: 300), cornerWidth: 56, cornerHeight: 56, transform: nil))
    ctx.setFillColor(cg(255, 255, 255, 0.96))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: cg(0, 0, 0, 0))
    var m = 0
    while m < 4 {
        let bx = 236.0 + Double(m) * 150.0
        ctx.addPath(CGPath(roundedRect: CGRect(x: bx, y: 380, width: 96, height: 200), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(m % 2 == 0 ? cg(16, 185, 129) : cg(79, 70, 229))
        ctx.fillPath()
        m += 1
    }
    var n = 0
    while n < 9 {
        let p = 216.0 + Double(n) * 74.0
        capsule(ctx, CGPoint(x: p, y: 330), CGPoint(x: p, y: 268), 20, cg(251, 191, 36))
        n += 1
    }
    ctx.setStrokeColor(cg(255, 255, 255))
    ctx.setLineWidth(56)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 300, y: 150))
    ctx.addLine(to: CGPoint(x: 512, y: 230))
    ctx.addLine(to: CGPoint(x: 724, y: 150))
    ctx.strokePath()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let a = newCtx(); drawA(a); savePNG(a, outDir + "/icon-A.png")
let b2 = newCtx(); drawB(b2); savePNG(b2, outDir + "/icon-B.png")
let c2 = newCtx(); drawC(c2); savePNG(c2, outDir + "/icon-C.png")
