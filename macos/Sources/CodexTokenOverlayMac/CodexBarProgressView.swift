import SwiftUI

struct CodexBarProgressView: View {
    private static let paceStripeCount = 3
    private static let stripePunchOpacity = 0.9

    private static func paceStripeWidth(for scale: CGFloat) -> CGFloat {
        2
    }

    private static func paceStripeSpan(for scale: CGFloat) -> CGFloat {
        let stripeCount = max(1, Self.paceStripeCount)
        return Self.paceStripeWidth(for: scale) * CGFloat(stripeCount)
    }

    let percent: Double
    let tint: Color
    let accessibilityLabel: String
    let pacePercent: Double?
    let paceOnTop: Bool
    let isHighlighted: Bool
    @Environment(\.displayScale) private var displayScale

    init(
        percent: Double,
        tint: Color,
        accessibilityLabel: String,
        pacePercent: Double? = nil,
        paceOnTop: Bool = true,
        isHighlighted: Bool = false)
    {
        self.percent = percent
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.pacePercent = pacePercent
        self.paceOnTop = paceOnTop
        self.isHighlighted = isHighlighted
    }

    private var clamped: Double {
        min(100, max(0, self.percent))
    }

    var body: some View {
        Canvas { context, size in
            let scale = max(self.displayScale, 1)
            let fillPercent = Self.renderedFillPercent(self.clamped)
            let fillWidth = size.width * fillPercent / 100
            let paceWidth = size.width * Self.clampedPercent(self.pacePercent) / 100
            let tipWidth = max(25, size.height * 6.5)
            let stripeInset = 1 / scale
            let tipOffset = paceWidth - tipWidth + (Self.paceStripeSpan(for: scale) / 2) + stripeInset
            let showTip = self.pacePercent != nil && tipWidth > 0.5

            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            context.clip(to: Path(rect))

            let trackPath = Path { path in path.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(MenuHighlightStyle.progressTrack(self.isHighlighted)))

            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { path in path.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(
                    fillPath,
                    with: .color(MenuHighlightStyle.progressTint(self.isHighlighted, fallback: self.tint)))
            }

            if showTip {
                let isDeficit = self.paceOnTop == false
                let useDeficitRed = isDeficit && self.isHighlighted == false
                let stripeColor: Color = if self.isHighlighted {
                    .white
                } else if useDeficitRed {
                    .red
                } else {
                    .green
                }

                let tipSize = CGSize(width: tipWidth, height: size.height)
                let stripes = Self.paceStripePaths(size: tipSize, scale: scale)
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)

                context.blendMode = .destinationOut
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(Self.stripePunchOpacity)))
                context.blendMode = .normal

                context.fill(stripes.center.applying(shift), with: .color(stripeColor))
            }
        }
        .frame(height: 6)
        .accessibilityLabel(self.accessibilityLabel)
        .accessibilityValue("\(Self.displayPercent(self.clamped)) percent")
    }

    nonisolated static func renderedFillPercent(_ percent: Double) -> Double {
        let clamped = Self.clampedPercent(percent)
        let displayPercent = Self.displayPercent(clamped)
        if displayPercent <= 0 { return 0 }
        if displayPercent >= 100 { return 100 }
        return clamped
    }

    private static func paceStripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
        let rect = CGRect(origin: .zero, size: size)
        let extend = size.height * 2
        let stripeTopY: CGFloat = -extend
        let stripeBottomY: CGFloat = size.height + extend
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }

        let stripeWidth = Self.paceStripeWidth(for: scale)
        let punchWidth = stripeWidth * 3
        let stripeInset = 1 / scale
        let stripeAnchorX = align(rect.maxX - stripeInset)
        let stripeMinY = align(stripeTopY)
        let stripeMaxY = align(stripeBottomY)
        let anchorTopX = stripeAnchorX
        var punchedStripe = Path()
        var centerStripe = Path()
        let availableWidth = (anchorTopX - punchWidth) - rect.minX
        guard availableWidth >= 0 else { return (punchedStripe, centerStripe) }

        let punchRightTopX = align(anchorTopX)
        let punchLeftTopX = punchRightTopX - punchWidth
        let punchRightBottomX = punchRightTopX
        let punchLeftBottomX = punchLeftTopX
        punchedStripe.addPath(Path { path in
            path.move(to: CGPoint(x: punchLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: punchLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        let centerLeftTopX = align(punchLeftTopX + (punchWidth - stripeWidth) / 2)
        let centerRightTopX = centerLeftTopX + stripeWidth
        let centerRightBottomX = centerRightTopX
        let centerLeftBottomX = centerLeftTopX
        centerStripe.addPath(Path { path in
            path.move(to: CGPoint(x: centerLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: centerLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        return (punchedStripe, centerStripe)
    }

    private nonisolated static func displayPercent(_ percent: Double) -> Int {
        Int(self.clampedPercent(percent).rounded())
    }

    private nonisolated static func clampedPercent(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(100, max(0, value))
    }

    private enum MenuHighlightStyle {
        static let selectionText = Color(nsColor: .selectedMenuItemTextColor)

        static func progressTrack(_ highlighted: Bool) -> Color {
            highlighted ? self.selectionText.opacity(0.22) : Color(nsColor: .tertiaryLabelColor).opacity(0.22)
        }

        static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
            highlighted ? self.selectionText : fallback
        }
    }
}
