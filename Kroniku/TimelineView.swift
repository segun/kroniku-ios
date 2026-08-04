import SwiftUI
import SwiftData

struct TimelineView: View {
    @Binding var showsCapture: Bool

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @State private var events: [MemoryEvent] = []
    @State private var selectedDate = Date()
    @State private var showsDatePicker = false

    private let calendar = Calendar.current

    private var isShowingToday: Bool {
        calendar.isDate(selectedDate, inSameDayAs: Date())
    }

    private var filteredEvents: [MemoryEvent] {
        events.filter { event in
            guard let occurredAt = event.occurredAt else { return false }
            return calendar.isDate(occurredAt, inSameDayAs: selectedDate)
        }
    }

    private var sortedEvents: [MemoryEvent] {
        filteredEvents.sorted { lhs, rhs in
            let lhsDate = lhs.occurredAt ?? .distantFuture
            let rhsDate = rhs.occurredAt ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            let lhsTitle = lhs.title ?? ""
            let rhsTitle = rhs.title ?? ""
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func loadEvents() {
        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        events = repo.fetchAll()
    }

    var body: some View {
        NavigationStack {
            KronikuHeroShell(title: heroTitle, subtitle: "Memory Timeline") {
                daySummary

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Timeline")
                            .font(.title3.weight(.semibold))
                            .fontDesign(.rounded)
                        Spacer()
                        Text("\(sortedEvents.count) events")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if sortedEvents.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(sortedEvents) { event in
                                if event.isReadOnlySource {
                                    TimelineRow(event: event)
                                } else {
                                    NavigationLink(destination: ContactMomentDetailView(event: event)) {
                                        TimelineRow(event: event)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .kronikuCard(.context)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsCapture = true } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(KronikuPalette.paper)
                            .frame(width: 34, height: 34)
                            .background(KronikuPalette.emberGradient, in: Circle())
                    }
                    .accessibilityLabel("Add a memory")
                }
            }
        }
        .onAppear {
            loadEvents()
            Task { await refreshCalendarEvents() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryRepositoryChanged)) { _ in
            loadEvents()
            Task { await refreshCalendarEvents() }
        }
        .onChange(of: selectedDate) { _, _ in
            loadEvents()
            Task { await refreshCalendarEvents() }
        }
        .sheet(isPresented: $showsDatePicker) {
            NavigationStack {
                VStack(spacing: 20) {
                    DatePicker(
                        "Timeline date",
                        selection: $selectedDate,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()

                    if !isShowingToday {
                        Button("Back to Today") {
                            selectedDate = Date()
                        }
                        .font(.headline)
                    }

                    Spacer()
                }
                .padding()
                .navigationTitle("Choose a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsDatePicker = false }
                            .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var heroTitle: String {
        if isShowingToday {
            return "Today, remembered"
        }
        return selectedDate.formatted(.dateTime.weekday(.wide).month().day())
    }

    private var daySummary: some View {
        HStack(spacing: 10) {
            Button {
                showsDatePicker = true
            } label: {
                statChip(icon: "calendar", title: selectedDate.formatted(.dateTime.weekday(.abbreviated).month().day()))
            }
            .buttonStyle(.plain)

            if !isShowingToday {
                Button {
                    selectedDate = Date()
                } label: {
                    statChip(icon: "arrow.uturn.backward", title: "Today")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(icon: String, title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(KronikuPalette.paper)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(KronikuPalette.heroGradient, in: Capsule())
    }

    private var emptyStateMessage: String {
        if isShowingToday {
            return "Tap the + button to save a contact moment. Calendar imports appear after consent."
        }
        return "No events were recorded for this day. Pick another date or jump back to today."
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No memories yet")
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func refreshCalendarEvents() async {
        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        await contextController.syncCalendarEvents(into: repo, for: selectedDate)
        loadEvents()
    }
}

private struct TimelineRow: View {
    let event: MemoryEvent

    private var contextHighlights: [String] {
        var highlights: [String] = []

        if let weather = event.weatherSnapshot,
           let condition = weather.condition,
           let temperatureC = weather.temperatureC {
            highlights.append("\(condition) \(Int(temperatureC.rounded()))C")
        }

        if let place = event.place?.name, !place.isEmpty {
            highlights.append(place)
        }

        let metadata = event.contextCard?.metadata ?? []
        for entry in metadata {
            switch entry.key {
            case "interactionType", "captureMethod", "location", "weather", "visit":
                continue
            default:
                if !entry.value.isEmpty {
                    highlights.append(entry.value.replacingOccurrences(of: ",", with: " · "))
                }
            }
        }

        var deduped: [String] = []
        for item in highlights where !deduped.contains(item) {
            deduped.append(item)
        }
        return Array(deduped.prefix(3))
    }

    private var rowFill: LinearGradient {
        event.isReadOnlySource
            ? KronikuCardTone.calendar.fill
            : KronikuCardTone.neutral.fill
    }

    private var rowBorder: Color {
        event.isReadOnlySource
            ? KronikuCardTone.calendar.borderColor
            : Color.black.opacity(0.05)
    }

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
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute())
        }
        return "--:--"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(KronikuPalette.night.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 74, alignment: .leading)

            Image(systemName: event.symbolName ?? "circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color(for: event.colorName))
                .frame(width: 34, height: 34)
                .background(color(for: event.colorName).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title ?? "Untitled")
                    .font(.body.weight(.semibold))
                    .fontDesign(.rounded)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let context = event.context, !context.isEmpty {
                    Text(context)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !contextHighlights.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(contextHighlights, id: \.self) { item in
                                Text(item)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(KronikuPalette.night)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(KronikuPalette.sand.opacity(0.95), in: Capsule())
                            }
                        }
                    }
                }
                if event.isReadOnlySource {
                    Text("Read-only calendar")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KronikuPalette.night)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(KronikuPalette.sand, in: Capsule())
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(rowBorder, lineWidth: 1)
        )
    }
}
