import CoreGraphics

/// カードの節 (CPU・メモリ・週間予報など)。カードは節を上から順に積んで作る。
public struct CardSection {
    public let height: CGFloat
    /// 節を描く。引数は描画先と、節の上端の y
    public let draw: (_ context: CGContext, _ top: CGFloat) -> Void

    public init(height: CGFloat, draw: @escaping (_ context: CGContext, _ top: CGFloat) -> Void) {
        self.height = height
        self.draw = draw
    }
}

public extension Array where Element == CardSection {
    /// 節を積んだときの高さ。節の間に `gap` ずつ空ける。
    func totalHeight(gap: CGFloat) -> CGFloat {
        map(\.height).reduce(0, +) + gap * CGFloat(Swift.max(count - 1, 0))
    }

    /// 節を上から順に描き、節の間の真ん中に `drawRule` で区切り線を引く。
    /// `drawRule` の引数は線の y。
    func drawStacked(in context: CGContext, gap: CGFloat, drawRule: (_ y: CGFloat) -> Void) {
        var top: CGFloat = 0
        for (index, section) in enumerated() {
            section.draw(context, top)
            top += section.height
            if index < count - 1 {
                drawRule(top + gap / 2)
                top += gap
            }
        }
    }
}
