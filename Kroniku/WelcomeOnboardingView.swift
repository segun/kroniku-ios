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
            symbolName: "book.pages.fill",
            eyebrow: "Kroniku",
            title: "A diary that writes itself",
            subtitle: "No typing, no forgetting. Kroniku quietly turns the moments of your day into a story worth keeping.",
            tint: KronikuPalette.emberGradient
        ),
        WelcomeOnboardingPage(
            index: 1,
            symbolName: "point.3.connected.trianglepath.dotted",
            eyebrow: "Context, fused",
            title: "Your life. Remembered.",
            subtitle: "Places, people, weather, and how your day felt — woven into every memory, automatically.",
            tint: LinearGradient(colors: [Color(red: 0.55, green: 0.68, blue: 0.98), Color(red: 0.30, green: 0.42, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        WelcomeOnboardingPage(
            index: 2,
            symbolName: "calendar.day.timeline.left",
            eyebrow: "Always in order",
            title: "A timeline, beautifully organized",
            subtitle: "Every entry finds its place — searchable, meaningful, and easy to look back on.",
            tint: LinearGradient(colors: [Color(red: 0.45, green: 0.82, blue: 0.60), Color(red: 0.22, green: 0.58, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        ),
        WelcomeOnboardingPage(
            index: 3,
            symbolName: "lock.shield.fill",
            eyebrow: "Your rules",
            title: "Your story stays yours",
            subtitle: "Every context source is opt-in. You decide what Kroniku remembers, and you can change your mind anytime.",
            tint: KronikuPalette.heroGradient
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
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    WelcomeOnboardingView(onFinish: {})
}
