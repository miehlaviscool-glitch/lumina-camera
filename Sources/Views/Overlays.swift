import SwiftUI

let gold = Color(red: 1.0, green: 0.80, blue: 0.25)

struct GridOverlay: View {
    let style: GridStyle
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                switch style {
                case .off: break
                case .thirds:
                    for i in 1...2 {
                        let x = w * CGFloat(i) / 3, y = h * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                case .golden:
                    let a = 0.382, b = 0.618
                    for f in [a, b] {
                        p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                        p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                    }
                case .diagonal:
                    p.move(to: .zero); p.addLine(to: CGPoint(x: w, y: h))
                    p.move(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: 0, y: h))
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

struct LevelOverlay: View {
    let angle: Double
    var body: some View {
        if angle.isNaN {
            EmptyView()
        } else {
            let level = abs(angle) < 0.03
            ZStack {
                Rectangle().fill(level ? gold : Color.white.opacity(0.85))
                    .frame(width: level ? 150 : 110, height: 2)
                    .rotationEffect(.radians(-angle))
                HStack(spacing: 120) {
                    Rectangle().fill(Color.white.opacity(0.5)).frame(width: 18, height: 1.5)
                    Rectangle().fill(Color.white.opacity(0.5)).frame(width: 18, height: 1.5)
                }
            }
            .animation(.easeOut(duration: 0.1), value: level)
            .allowsHitTesting(false)
        }
    }
}

struct HistogramView: View {
    let bins: [Float]
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<bins.count, id: \.self) { i in
                    Rectangle().fill(Color.white.opacity(0.85))
                        .frame(width: g.size.width / CGFloat(max(bins.count, 1)),
                               height: max(1, CGFloat(bins[i]) * g.size.height))
                }
            }
        }
        .frame(width: 110, height: 44)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}

struct FocusReticle: View {
    @State private var appeared = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(gold, lineWidth: 1.5)
            .frame(width: 74, height: 74)
            .scaleEffect(appeared ? 1 : 1.4)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct Chip: View {
    let title: String
    var icon: String?
    var selected = false
    var tint: Color = gold
    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(selected ? .black : .white)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(selected ? tint : Color.white.opacity(0.16), in: Capsule())
    }
}
