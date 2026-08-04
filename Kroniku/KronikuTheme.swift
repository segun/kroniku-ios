import SwiftUI

enum KronikuPalette {
    static let ink = Color(red: 0.051, green: 0.071, blue: 0.149)
    static let night = Color(red: 0.086, green: 0.110, blue: 0.239)
    static let ember = Color(red: 0.910, green: 0.439, blue: 0.247)
    static let apricot = Color(red: 0.949, green: 0.726, blue: 0.420)
    static let fog = Color(red: 0.537, green: 0.569, blue: 0.769)
    static let sand = Color(red: 0.969, green: 0.957, blue: 0.925)
    static let paper = Color.white

    static let heroGradient = LinearGradient(
        colors: [ink, night],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let emberGradient = LinearGradient(
        colors: [apricot, ember],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let canvasGradient = LinearGradient(
        colors: [sand, Color(red: 0.955, green: 0.941, blue: 0.898)],
        startPoint: .top,
        endPoint: .bottom
    )
}

enum KronikuCardTone {
    case neutral
    case calendar
    case context
    case semantics

    var fill: LinearGradient {
        switch self {
        case .neutral:
            return LinearGradient(
                colors: [Color.white, Color(red: 0.982, green: 0.970, blue: 0.938)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .calendar:
            return LinearGradient(
                colors: [Color(red: 1.000, green: 0.978, blue: 0.930), Color(red: 0.983, green: 0.945, blue: 0.865)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .context:
            return LinearGradient(
                colors: [Color(red: 0.952, green: 0.966, blue: 1.000), Color(red: 0.919, green: 0.940, blue: 0.992)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .semantics:
            return LinearGradient(
                colors: [Color(red: 0.949, green: 1.000, blue: 0.955), Color(red: 0.908, green: 0.978, blue: 0.925)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var borderColor: Color {
        switch self {
        case .neutral: return Color.black.opacity(0.06)
        case .calendar: return KronikuPalette.apricot.opacity(0.5)
        case .context: return KronikuPalette.fog.opacity(0.5)
        case .semantics: return Color(red: 0.360, green: 0.700, blue: 0.450).opacity(0.35)
        }
    }
}

struct KronikuCardStyle: ViewModifier {
    let tone: KronikuCardTone

    func body(content: Content) -> some View {
        content
            .padding(16)
            .foregroundStyle(KronikuPalette.ink)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(tone.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(tone.borderColor, lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func kronikuCard(_ tone: KronikuCardTone = .neutral) -> some View {
        modifier(KronikuCardStyle(tone: tone))
    }
}

struct KronikuLogoRow: View {
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image("KronikuLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Kroniku")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(KronikuPalette.paper)
                Text(subtitle.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(1.2)
                    .foregroundStyle(KronikuPalette.fog)
            }

            Spacer()
        }
    }
}

struct KronikuHeroShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            KronikuPalette.canvasGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        KronikuLogoRow(subtitle: subtitle)

                        Text(title)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(KronikuPalette.paper)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(KronikuPalette.emberGradient)
                            .frame(width: 98, height: 98)
                            .blur(radius: 12)
                            .offset(x: 22, y: -24)
                            .opacity(0.6)
                    }

                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }
}
