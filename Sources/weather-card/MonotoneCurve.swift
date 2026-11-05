import CoreGraphics

/// 点を通る滑らかな曲線 (単調な 3 次補間、Fritsch–Carlson の方法)。曲線は必ず点を通り、
/// 隣り合う 2 点の間で、その 2 点の値の範囲を超えて膨らまない (無い山や谷を作らない)。
/// x は増える順に並んでいること。
func monotoneCurve(through p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = p.first else { return path }
    path.move(to: first)
    guard p.count > 1 else { return path }
    let n = p.count

    // 区間ごとの傾き
    let d = (0..<n - 1).map { i in (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 0.0001) }

    // 点ごとの接線の傾き。端は区間の傾き、内側は両隣の区間の傾きの平均。向きが変わる
    // (山や谷の) 点では 0 にする。
    var m = [CGFloat](repeating: 0, count: n)
    m[0] = d[0]
    m[n - 1] = d[n - 2]
    for i in 1..<n - 1 {
        m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
    }

    // 行き過ぎないよう、接線を区間の傾きの 3 倍までに抑える
    for i in 0..<n - 1 {
        if d[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
            continue
        }
        let a = m[i] / d[i], b = m[i + 1] / d[i]
        let h = a * a + b * b
        if h > 9 {
            let t = 3 / h.squareRoot()
            m[i] = t * a * d[i]
            m[i + 1] = t * b * d[i]
        }
    }

    // エルミート曲線を 3 次ベジエ曲線にして描く
    for i in 0..<n - 1 {
        let dx = (p[i + 1].x - p[i].x) / 3
        path.addCurve(to: p[i + 1],
                      control1: CGPoint(x: p[i].x + dx, y: p[i].y + m[i] * dx),
                      control2: CGPoint(x: p[i + 1].x - dx, y: p[i + 1].y - m[i + 1] * dx))
    }
    return path
}
