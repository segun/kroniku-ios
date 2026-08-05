import SwiftUI
import SwiftData

struct TimelineView: View {
    private enum TimelineFilter: String, CaseIterable, Identifiable {
        case places
        case interactions
        case calendar
        case weather
        case motion
        case health
        case photos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .places: return "Places"
            case .interactions: return "Interactions"
            case .calendar: return "Calendar"
            case .weather: return "Weather"
            case .motion: return "Motion"
            case .health: return "Health"
            case .photos: return "Photos"
            }
        }

        var icon: String {
            switch self {
            case .places: return "mappin.and.ellipse"
            case .interactions: return "person.2"
            case .calendar: return "calendar"
            case .weather: return "cloud.sun"
            case .motion: return "figure.walk"
            case .health: return "heart.text.square"
            case .photos: return "photo"
            }
        }
    }

    @Binding var showsCapture: Bool

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @State private var events: [MemoryEvent] = []
    @State private var selectedDate = Date()
    @State private var showsDatePicker = false
    @State private var selectedFilters: Set<TimelineFilter> = []
    @State private var hiddenEventIDs: Set<UUID> = []
    @State private var showsHiddenEvents = false
    @State private var selectedEvent: MemoryEvent?
    @State private var actionEvent: MemoryEvent?

    private let calendar = Calendar.current

    private var isShowingToday: Bool {
        calendar.isDate(selectedDate, inSameDayAs: Date())
    }

    private var filteredEvents: [MemoryEvent] {
        events.filter { event in
            guard let occurredAt = event.occurredAt else { return false }
            guard calendar.isDate(occurredAt, inSameDayAs: selectedDate) else { return false }
            guard !hiddenEventIDs.contains(event.id) else { return false }
            return selectedFilters.allSatisfy { matches(filter: $0, event: event) }
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

    private var hiddenEvents: [MemoryEvent] {
        events.filter { event in
            guard hiddenEventIDs.contains(event.id) else { return false }
            guard let occurredAt = event.occurredAt else { return false }
            return calendar.isDate(occurredAt, inSameDayAs: selectedDate)
        }
    }

    private var sortedHiddenEvents: [MemoryEvent] {
        hiddenEvents.sorted { lhs, rhs in
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
            KronikuHeroShell(title: heroTitle, subtitle: "Timeline") {
                daySummary
                filterStrip

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
                                TimelineRow(event: event)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if !event.isReadOnlySource {
                                            selectedEvent = event
                                        }
                                    }
                                    .onLongPressGesture(minimumDuration: 0.45) {
                                        actionEvent = event
                                    }
                            }
                        }
                    }

                    if !sortedHiddenEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Hidden")
                                    .font(.headline.weight(.semibold))
                                    .fontDesign(.rounded)

                                Spacer()

                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showsHiddenEvents.toggle()
                                    }
                                } label: {
                                    Image(systemName: showsHiddenEvents ? "chevron.down" : "chevron.right")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(KronikuPalette.night)
                                        .frame(width: 32, height: 32)
                                        .background(KronikuPalette.sand.opacity(0.85), in: Circle())
                                }
                                .buttonStyle(.plain)
                            }

                            if showsHiddenEvents {
                                LazyVStack(spacing: 10) {
                                    ForEach(sortedHiddenEvents) { event in
                                        ZStack(alignment: .topTrailing) {
                                            TimelineRow(event: event)
                                                .opacity(0.56)
                                            Text("Hidden")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(KronikuPalette.night)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(KronikuPalette.sand, in: Capsule())
                                                .padding(10)
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            Button {
                                                hiddenEventIDs.remove(event.id)
                                            } label: {
                                                Label("Show", systemImage: "eye")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.teal)
                                            .padding(10)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .kronikuCard(.context)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedEvent) { event in
                ContactMomentDetailView(event: event)
            }
            .sheet(item: $actionEvent) { event in
                TimelineEventActionSheet(
                    event: event,
                    onEdit: {
                        if !event.isReadOnlySource {
                            selectedEvent = event
                        }
                        actionEvent = nil
                    },
                    onHide: {
                        hiddenEventIDs.insert(event.id)
                        actionEvent = nil
                    },
                    onCancel: {
                        actionEvent = nil
                    }
                )
                .presentationDetents([.height(240)])
                .presentationDragIndicator(.visible)
            }
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
            return "Today"
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
        if !selectedFilters.isEmpty {
            return "No memories match the active filters for this day. Clear one or more filters to widen the timeline."
        }
        if isShowingToday {
            return "Tap the + button to save a contact moment. Calendar imports appear after consent."
        }
        return "No events were recorded for this day. Pick another date or jump back to today."
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimelineFilter.allCases) { filter in
                    Button {
                        toggle(filter)
                    } label: {
                        Label(filter.title, systemImage: filter.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedFilters.contains(filter) ? KronikuPalette.paper : KronikuPalette.night)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                selectedFilters.contains(filter)
                                    ? AnyShapeStyle(KronikuPalette.heroGradient)
                                    : AnyShapeStyle(KronikuPalette.sand.opacity(0.92)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ filter: TimelineFilter) {
        if selectedFilters.contains(filter) {
            selectedFilters.remove(filter)
        } else {
            selectedFilters.insert(filter)
        }
    }

    private func matches(filter: TimelineFilter, event: MemoryEvent) -> Bool {
        switch filter {
        case .places:
            return event.place != nil
        case .interactions:
            return event.source == "contactMoment"
        case .calendar:
            return event.source == "calendar"
        case .weather:
            return event.weatherSnapshot != nil
        case .motion:
            return event.contextCard?.metadata.contains(where: { $0.key == "motion" }) ?? false
        case .health:
            return event.healthSummary?.entries.isEmpty == false
        case .photos:
            return !event.photoAttachments.isEmpty
        }
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

private struct TimelineEventActionSheet: View {
    let event: MemoryEvent
    let onEdit: () -> Void
    let onHide: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(event.title ?? "Untitled")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(KronikuPalette.apricot)
            .foregroundStyle(KronikuPalette.night)
            .disabled(event.isReadOnlySource)

            Button {
                onHide()
            } label: {
                Label("Hide", systemImage: "eye.slash")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.910, green: 0.439, blue: 0.247))

            Button("Cancel") {
                onCancel()
            }
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }
}

private struct TimelineRow: View {
    let event: MemoryEvent

    private var shouldShowContextText: Bool {
        guard let context = event.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return false
        }
        guard event.source == "contactMoment" else { return true }
        let redundantInteractionLabels: Set<String> = ["call", "text", "meeting"]
        return !redundantInteractionLabels.contains(context.lowercased())
    }

    private struct ContextChip: Identifiable, Hashable {
        let id: String
        var text: String
        var icon: String
    }

    private var metadataByKey: [String: String] {
        var values: [String: String] = [:]
        for entry in event.contextCard?.metadata ?? [] {
            if values[entry.key] == nil {
                values[entry.key] = entry.value
            }
        }
        return values
    }

    private var contextChips: [ContextChip] {
        var chips: [ContextChip] = []

        if let placeText = preferredPlaceText {
            chips.append(.init(id: "place", text: placeText, icon: "mappin.and.ellipse"))
        }

        if let weatherText = preferredWeatherText {
            chips.append(.init(id: "weather", text: weatherText, icon: weatherIcon(for: weatherText)))
        }

        if let motion = metadataByKey["motion"], !motion.isEmpty {
            chips.append(.init(id: "motion", text: motion.capitalized, icon: motionIcon(for: motion)))
        }

        if let bluetooth = metadataByKey["bluetoothContext"], !bluetooth.isEmpty {
            chips.append(.init(id: "bluetooth", text: bluetooth.capitalized, icon: bluetoothIcon(for: bluetooth)))
        }

        if let whenLabels = metadataByKey["timeSemantics"], !whenLabels.isEmpty {
            chips.append(.init(id: "when", text: whenLabels.replacingOccurrences(of: ",", with: " · "), icon: "clock.badge.checkmark"))
        }

        if let attendees = metadataByKey["attendees"], !attendees.isEmpty {
            chips.append(.init(id: "attendees", text: attendees, icon: "person.2"))
        }

        if let healthSummary = event.healthSummary, !healthSummary.entries.isEmpty {
            for entry in healthSummary.entries {
                chips.append(.init(id: "health-\(entry.metric.rawValue)", text: entry.value, icon: "heart.text.square"))
            }
        }

        if !event.photoAttachments.isEmpty {
            let count = event.photoAttachments.count
            chips.append(.init(id: "photos", text: count == 1 ? "1 photo" : "\(count) photos", icon: "photo"))
        }

        if let score = event.confidenceScore {
            chips.append(.init(id: "confidence", text: "\(Int((score * 100).rounded()))% confidence", icon: "checkmark.shield"))
        }

        var deduped: [ContextChip] = []
        for chip in chips {
            let normalized = chip.text.lowercased()
            if !deduped.contains(where: { $0.id == chip.id || $0.text.lowercased() == normalized }) {
                deduped.append(chip)
            }
        }

        return Array(deduped.prefix(5))
    }

    private var preferredPlaceText: String? {
        if let place = event.place?.name, !place.isEmpty {
            return place
        }
        if let visit = metadataByKey["visit"], !visit.isEmpty {
            return visit
        }
        if let location = metadataByKey["location"], !location.isEmpty {
            return location
        }
        return nil
    }

    private var preferredWeatherText: String? {
        if let weather = event.weatherSnapshot,
           let condition = weather.condition,
           let temperatureC = weather.temperatureC {
            return "\(condition) \(Int(temperatureC.rounded()))C"
        }
        if let weather = metadataByKey["weather"], !weather.isEmpty {
            return weather.replacingOccurrences(of: ",", with: " ")
        }
        return nil
    }

    private func motionIcon(for motion: String) -> String {
        switch motion.lowercased() {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "driving": return "car"
        case "cycling": return "bicycle"
        case "stationary": return "figure.stand"
        default: return "figure.walk"
        }
    }

    private func weatherIcon(for weatherText: String) -> String {
        let text = weatherText.lowercased()
        if text.contains("thunder") { return "cloud.bolt.rain" }
        if text.contains("rain") || text.contains("drizzle") || text.contains("shower") { return "cloud.rain" }
        if text.contains("snow") { return "cloud.snow" }
        if text.contains("fog") || text.contains("mist") { return "cloud.fog" }
        if text.contains("overcast") || text.contains("cloud") { return "cloud" }
        if text.contains("clear") || text.contains("sun") { return "sun.max" }
        return "cloud.sun"
    }

    private func bluetoothIcon(for value: String) -> String {
        switch value.lowercased() {
        case "car": return "car"
        case "headphones": return "headphones"
        case "speaker": return "hifispeaker"
        default: return "dot.radiowaves.left.and.right"
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(timeText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(KronikuPalette.night.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: event.symbolName ?? "circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color(for: event.colorName))
                    .frame(width: 34, height: 34)
                    .background(color(for: event.colorName).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title ?? "Untitled")
                        .font(.body.weight(.semibold))
                        .fontDesign(.rounded)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    if shouldShowContextText, let context = event.context, !context.isEmpty {
                        Text(context)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if !contextChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(contextChips) { chip in
                                    Label(chip.text, systemImage: chip.icon)
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
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(rowBorder, lineWidth: 1)
        )
    }
}
