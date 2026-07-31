import SwiftUI
import SwiftData

struct TimelineView: View {
    @Binding var showsCapture: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var events: [MemoryEvent] = []

    private func loadEvents() {
        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        events = repo.fetchAll()
    }

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
                            NavigationLink(destination: ContactMomentDetailView(event: event)) {
                                TimelineRow(event: event)
                            }
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
        .onAppear { loadEvents() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryRepositoryChanged)) { _ in loadEvents() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(), format: .dateTime.weekday().month().day())
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
    let event: MemoryEvent

    private func color(for name: String?) -> Color {
        switch name {
        case "indigo": return .indigo
        case "orange": return .orange
        case "pink": return .pink
        case "red": return .red
        default: return .gray
        }
    }

    private var timeText: String {
        if let date = event.occurredAt {
            return date.formatted(.dateTime.hour().minute())
        }
        return "--:--"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            VStack(spacing: 0) {
                Image(systemName: event.symbolName ?? "circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: event.colorName))
                    .frame(width: 32, height: 32)
                    .background(color(for: event.colorName).opacity(0.12), in: Circle())
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title ?? "Untitled").font(.body.weight(.semibold))
                if let detail = event.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                if let context = event.context {
                    Text(context)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
