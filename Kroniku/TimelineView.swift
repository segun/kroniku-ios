import SwiftUI

struct TimelineView: View {
    @Binding var showsCapture: Bool

    private let events = TimelineEvent.preview

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    daySummary
                    Label("Today", systemImage: "calendar")
                        .font(.title3.weight(.semibold))

                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            TimelineRow(event: event)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Kroniku")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsCapture = true } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Add a memory")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Thursday, July 23")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("A day worth remembering.")
                .font(.largeTitle.bold())
        }
    }

    private var daySummary: some View {
        HStack(spacing: 16) {
            Label("28° · Sunny", systemImage: "sun.max.fill")
            Divider()
            Label("3 places", systemImage: "mappin.and.ellipse")
            Divider()
            Label("42 km", systemImage: "car.fill")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TimelineRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(event.time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            VStack(spacing: 0) {
                Image(systemName: event.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(event.color)
                    .frame(width: 32, height: 32)
                    .background(event.color.opacity(0.12), in: Circle())
                if event.id != TimelineEvent.preview.last?.id {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.body.weight(.semibold))
                Text(event.detail).font(.subheadline).foregroundStyle(.secondary)
                if let context = event.context {
                    Text(context)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(event.color)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

private struct TimelineEvent: Identifiable {
    let id = UUID()
    let time: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let context: String?

    static let preview = [
        TimelineEvent(time: "08:40", title: "Drive to Victoria Island", detail: "14.2 km · 31 min", symbol: "car.fill", color: .indigo, context: "Sunny · light traffic"),
        TimelineEvent(time: "09:30", title: "Product meeting", detail: "Mr. Kroenke · Eko Hotel", symbol: "person.2.fill", color: .orange, context: "From your calendar"),
        TimelineEvent(time: "12:18", title: "Lunch at Nok", detail: "Victoria Island", symbol: "fork.knife", color: .pink, context: nil),
        TimelineEvent(time: "15:05", title: "Drive home", detail: "13.7 km · 38 min", symbol: "car.fill", color: .indigo, context: "Light rain"),
    ]
}
