import AppKit
import SwiftUI

/// Compact menu-bar mark: orbital ring (remaining capacity) + center glyph (source).
///
/// MenuBarExtra often drops bare `Canvas` / complex SwiftUI; we render a **template NSImage**
/// so the mark is always visible next to the percentage text.
struct MenuBarStatusIcon: View {
    enum Kind: Equatable {
        case idle
        case live
        case provider
    }

    var remainingPercent: Double?
    var kind: Kind

    /// Menu bar point size (logical). Rendered @2x for sharpness.
    private let pointSize: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.render(
            remainingPercent: remainingPercent,
            kind: kind,
            pointSize: pointSize
        ))
        .renderingMode(.template)
        .frame(width: pointSize, height: pointSize)
        .accessibilityHidden(true)
    }

    // MARK: - Rasterize for MenuBarExtra

    static func render(
        remainingPercent: Double?,
        kind: Kind,
        pointSize: CGFloat
    ) -> NSImage {
        let scale: CGFloat = 2
        let pixel = max(16, Int((pointSize * scale).rounded()))
        let size = NSSize(width: pixel, height: pixel)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(
                in: ctx,
                rect: rect,
                remainingPercent: remainingPercent,
                kind: kind
            )
            return true
        }
        image.isTemplate = true
        // Report logical size so SwiftUI/AppKit places it at ~16pt.
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    private static func draw(
        in ctx: CGContext,
        rect: CGRect,
        remainingPercent: Double?,
        kind: Kind
    ) {
        let inset = rect.width * 0.08
        let bounds = rect.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 * 0.92
        let lineW = max(1.6, rect.width * 0.11)

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Track
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(kind == .idle ? 0.28 : 0.32).cgColor)
        ctx.setLineWidth(lineW * 0.85)
        ctx.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ctx.strokePath()

        let remaining = remainingPercent.map { min(100, max(0, $0)) }

        if let remaining, remaining > 0.5 {
            let fraction = remaining / 100
            // AppKit/CG: 0° is 3 o'clock, positive is counter-clockwise.
            // We want 12 o'clock start, sweep clockwise for remaining.
            // Clockwise remaining from 12 o'clock = counter-clockwise in CG math with negative sweep… 
            // Start at top (π/2 in standard math from positive x, but CG uses flipped in NSImage drawing sometimes).
            // NSImage flipped:false uses bottom-left origin, y up — same as CG.
            let start = CGFloat(-Double.pi / 2) // 12 o'clock
            let sweep = CGFloat(2 * Double.pi * fraction)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(remaining < 18 ? 0.75 : 1.0).cgColor)
            ctx.setLineWidth(remaining < 18 ? lineW * 0.95 : lineW)
            ctx.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start + sweep,
                clockwise: false
            )
            ctx.strokePath()

            if fraction < 0.97 {
                let endAngle = start + sweep
                let beadR = max(1.4, lineW * 0.55)
                let ex = center.x + radius * cos(endAngle)
                let ey = center.y + radius * sin(endAngle)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: ex - beadR, y: ey - beadR, width: beadR * 2, height: beadR * 2))
            }
        } else if kind == .live || kind == .idle {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(kind == .live ? 0.55 : 0.38).cgColor)
            ctx.setLineWidth(lineW * 0.8)
            ctx.setLineDash(phase: 0, lengths: [rect.width * 0.08, rect.width * 0.1])
            ctx.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Center SF Symbol as template bitmap
        let glyph = centerGlyph(kind: kind, remainingPercent: remaining)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: rect.width * glyph.relativeSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: glyph.systemName, accessibilityDescription: nil),
              let configured = base.withSymbolConfiguration(symbolConfig)
        else { return }

        let symbolSize = configured.size
        let symbolRect = CGRect(
            x: center.x - symbolSize.width / 2,
            y: center.y - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        ctx.saveGState()
        ctx.setAlpha(glyph.opacity)
        // Draw as black for template
        configured.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()
    }

    private static func centerGlyph(
        kind: Kind,
        remainingPercent: Double?
    ) -> (systemName: String, relativeSize: CGFloat, opacity: CGFloat) {
        switch kind {
        case .idle:
            return ("bolt.horizontal", 0.34, 0.55)
        case .live:
            return ("bolt.horizontal.fill", 0.34, 0.9)
        case .provider:
            if let p = remainingPercent, p < 18 {
                return ("sparkle", 0.32, 0.8)
            }
            return ("bolt.horizontal.fill", 0.32, 0.95)
        }
    }
}
