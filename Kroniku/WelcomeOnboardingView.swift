import SwiftUI

/// Content for a single pre-login onboarding slide.
private struct WelcomeOnboardingPage: Identifiable {
    var id: Int { index }

    let index: Int
    let symbolName: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let tint: LinearGradient
}

/// Full-screen marketing carousel shown once, before the sign-in screen.
struct WelcomeOnboardingView: View {
    var onFinish: () -> Void

    @State private var currentPage = 0
    @State private var floatUp = false

    private let pages: [WelcomeOnboardingPage] = [
        WelcomeOnboardingPage(
            index: 0,
            symbolName: "book.closed.fill",
            eyebrow: "Welcome to Kroniku",
            title: "A diary that writes itself",
            subtitle: "Kroniku turns the traces of daily life into one calm timeline, so you can remember your day without having to log every moment.",
            tint: KronikuPalette.emberGradient
        ),
        WelcomeOnboardingPage(
            index: 1,
            symbolName: "cpu.fill",
            eyebrow: "Already on your device",
            title: "It was there all along",
            subtitle: "Kroniku quietly draws on what your device already has. It seamlessly connects your existing activity into one continuous daily memory",
            tint: LinearGradient(colors: [Color(red: 0.55, green: 0.68, blue: 0.98), Color(red: 0.30, green: 0.42, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        WelcomeOnboardingPage(
            index: 2,
            symbolName: "clock.arrow.circlepath",
            eyebrow: "Always in order",
            title: "A timeline, beautifully organized",
            subtitle: "Places, notes, photos and calendar events. Everything Kroniku gathers finds its place by time, turning into one searchable story you can look back on anytime.",
            tint: LinearGradient(colors: [Color(red: 0.45, green: 0.82, blue: 0.60), Color(red: 0.22, green: 0.58, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        WelcomeOnboardingPage(
            index: 3,
            symbolName: "sparkles",
            eyebrow: "Intelligent Summaries",
            title: "Memories, synthesized",
            subtitle: "Kroniku highlights themes, key moments, and insights from your day so you get the full story at a glance.",
            tint: LinearGradient(colors: [Color(red: 0.82, green: 0.50, blue: 0.90), Color(red: 0.55, green: 0.30, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        WelcomeOnboardingPage(
            index: 4,
            symbolName: "lock.shield.fill",
            eyebrow: "Your rules",
            title: "Private by design",
            subtitle: "Your personal data stays safely on your device. You have full control over what sources Kroniku accesses.",
            tint: KronikuPalette.heroGradient
        ),
        WelcomeOnboardingPage(
            index: 5,
            symbolName: "app.badge.checkmark.fill",
            eyebrow: "Seamless Setup",
            title: "Connect your dots",
            subtitle: "Enable access to your photos, calendar, activities, locations and notes so Kroniku can start weaving your daily timeline together.",
            tint: LinearGradient(colors: [Color(red: 0.95, green: 0.65, blue: 0.40), Color(red: 0.88, green: 0.40, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )        
    ]

    private var isLastPage: Bool { currentPage == pages.count - 1 }

    var body: some View {
        ZStack {
            KronikuPalette.canvasGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if !isLastPage {
                        Button("Skip") { onFinish() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KronikuPalette.ink.opacity(0.55))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .frame(height: 36)

                TabView(selection: $currentPage) {
                    ForEach(pages) { page in
                        WelcomeOnboardingPageView(page: page, floatUp: floatUp)
                            .tag(page.index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .clipped()
                .animation(.easeInOut, value: currentPage)

                VStack(spacing: 20) {
                    HStack(spacing: 8) {
                        ForEach(pages) { page in
                            Capsule()
                                .fill(page.index == currentPage ? KronikuPalette.ember : KronikuPalette.fog.opacity(0.35))
                                .frame(width: page.index == currentPage ? 22 : 8, height: 8)
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentPage)
                        }
                    }

                    Button(action: advance) {
                        Text(isLastPage ? "Get Started" : "Next")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(KronikuPalette.emberGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                floatUp = true
            }
        }
    }

    private func advance() {
        if isLastPage {
            onFinish()
        } else {
            withAnimation(.easeInOut) {
                currentPage += 1
            }
        }
    }
}

private struct WelcomeOnboardingPageView: View {
    let page: WelcomeOnboardingPage
    let floatUp: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .fill(page.tint)
                        .frame(width: 190, height: 190)
                        .blur(radius: 6)
                        .opacity(0.85)
                        .offset(y: floatUp ? -8 : 8)

                    Circle()
                        .fill(KronikuPalette.ink.opacity(0.82))
                        .frame(width: 146, height: 146)
                        .offset(y: floatUp ? -8 : 8)

                    Image(systemName: page.symbolName)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating.speed(0.6))
                        .offset(y: floatUp ? -8 : 8)
                }
                .padding(.top, 24)

                VStack(spacing: 10) {
                    Text(page.eyebrow.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(KronikuPalette.ember)

                    Text(page.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(KronikuPalette.ink)

                    Text(page.subtitle)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(KronikuPalette.ink.opacity(0.7))
                        .padding(.horizontal, 12)
                }

                if page.index == 1 {
                    aggregationPreview
                } else if page.index >= 2 {
                    timelinePreview
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var aggregationPreview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                sourcePill(symbolName: "calendar", label: "Events")
                sourcePill(symbolName: "mappin.and.ellipse", label: "Places")
                sourcePill(symbolName: "note.text", label: "Notes")
            }

            Image(systemName: "arrow.down")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(KronikuPalette.ember.opacity(0.8))
                .offset(y: floatUp ? 2 : -2)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 10) {
                        Text(["8:30", "12:15", "6:40"][index])
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(KronikuPalette.ember)
                            .frame(width: 42, alignment: .leading)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(KronikuPalette.ink.opacity(0.12))
                            .frame(width: [166, 202, 138][index], height: 10)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(14)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.76), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private func sourcePill(symbolName: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(KronikuPalette.ink.opacity(0.82), in: Circle())

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KronikuPalette.ink.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var timelinePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 8) {
                    Circle()
                        .fill(KronikuPalette.ember.opacity(0.8))
                        .frame(width: 7, height: 7)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(KronikuPalette.ink.opacity(0.12))
                        .frame(width: index == 1 ? 180 : 220, height: 10)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.75), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }
}

#Preview {
    WelcomeOnboardingView(onFinish: {})
}
