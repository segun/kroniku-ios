import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ContactMomentDetailView: View {
    private enum FocusField: Hashable {
        case contactName, note
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @Query(sort: \MemoryEvent.occurredAt, order: .reverse) private var allEvents: [MemoryEvent]
    @FocusState private var focusedField: FocusField?

    let event: MemoryEvent

    @State private var contactNames: [String] = []
    @State private var contactNameInput: String = ""
    @State private var note: String = ""
    @State private var interaction: Interaction = .moment
    @State private var occurredAt: Date = Date()
    @State private var endedAt: Date?
    @State private var hasEndTime = false
    // Kept mounted at all times so the DatePicker is never destroyed/recreated, which crashes on some iOS versions.
    @State private var endTimeDraft = Date()
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAttachments: [PhotoAttachment] = []
    @State private var isEditing = false
    @State private var selectedMapDestination: MapDestination?
    @State private var showsMapChooser = false
    @State private var selectedLinkedEvent: MemoryEvent?
    @State private var showsLinkedEventChooser = false

    private struct MapDestination {
        var query: String
        var coordinate: GeoCoordinate?
    }

    private var detailMetadata: [ContextCard.MetadataEntry] {
        let metadata = event.contextCard?.metadata ?? []
        return metadata.filter { entry in
            !(entry.key == "interactionType" || entry.key == "captureMethod" || entry.key == "visit" || entry.key == "contacts" || entry.key == "endedAt")
        }
    }

    private var trimmedContactNameInput: String {
        contactNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidTimeRange: Bool {
        guard let endedAt else { return true }
        return endedAt >= occurredAt
    }

    private var canSaveEdits: Bool {
        let hasContent = !(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contactNames.isEmpty)
        return hasContent && hasValidTimeRange
    }

    private var timeRangeText: String {
        let start = occurredAt.formatted(.dateTime.weekday().month().day().hour().minute())
        guard let endedAt else { return start }
        if Calendar.current.isDate(occurredAt, inSameDayAs: endedAt) {
            return "\(start) - \(endedAt.formatted(.dateTime.hour().minute()))"
        }
        return "\(start) - \(endedAt.formatted(.dateTime.weekday().month().day().hour().minute()))"
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

    private var linkedEvents: [MemoryEvent] {
        allEvents.filter { candidate in
            candidate.id != event.id && event.linkedEventIDs.contains(candidate.id)
        }
    }

    init(event: MemoryEvent) {
        self.event = event
        // initialize states from linked contact moment if available
        if let cm = event.contactMoment {
            let names = cm.contactNames.isEmpty ? [cm.personName].compactMap { $0 } : cm.contactNames
            _contactNames = State(initialValue: names)
            _note = State(initialValue: cm.note)
            _interaction = State(initialValue: Interaction(rawValue: cm.interactionType) ?? .moment)
            _occurredAt = State(initialValue: cm.occurredAt)
            _endedAt = State(initialValue: cm.endedAt)
            _hasEndTime = State(initialValue: cm.endedAt != nil)
            _endTimeDraft = State(initialValue: cm.endedAt ?? cm.occurredAt)
        } else {
            // fallback to MemoryEvent fields
            _contactNames = State(initialValue: [event.detail].compactMap { $0 }.filter { !$0.isEmpty })
            _note = State(initialValue: event.title ?? "")
            _occurredAt = State(initialValue: event.occurredAt ?? Date())
        }
        _photoAttachments = State(initialValue: event.photoAttachments)
    }

    var body: some View {
        ZStack {
            KronikuPalette.canvasGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.isReadOnlySource ? "Calendar detail" : "Moment")
                            .font(.title2.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(KronikuPalette.paper)
                        Text(event.isReadOnlySource ? "Read-only source metadata" : (isEditing ? "Edit" : "Details"))
                            .font(.subheadline)
                            .foregroundStyle(KronikuPalette.fog)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if event.isReadOnlySource {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Imported from calendar", systemImage: "calendar.badge.clock")
                                .font(.headline.weight(.semibold))
                                .fontDesign(.rounded)

                            if let contextCard = event.contextCard {
                                ForEach(contextCard.metadata) { entry in
                                    if entry.key == "location" {
                                        metadataRow(title: entry.key, value: entry.value, action: {
                                            openMapChooser(query: entry.value, coordinate: nil)
                                        })
                                    } else {
                                        metadataRow(title: entry.key, value: entry.value)
                                    }
                                }
                            }
                        }
                        .kronikuCard()
                    } else {
                        Group {
                            if isEditing {
                                editModeContent
                            } else {
                                viewModeContent
                            }
                        }
                        .kronikuCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .navigationTitle("Moment")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if !event.isReadOnlySource {
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") {
                            focusedField = nil
                            saveChanges()
                            isEditing = false
                        }
                        .fontWeight(.semibold)
                        .disabled(!canSaveEdits)
                    } else {
                        Button("Edit") {
                            isEditing = true
                        }
                        .fontWeight(.semibold)
                    }
                }

                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            focusedField = nil
                            reloadFromEvent()
                            isEditing = false
                        }
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadPhotoAttachments(from: newItems)
            }
        }
        .sheet(isPresented: $showsMapChooser) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose which app to open for this place.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        showsMapChooser = false
                        openSelectedDestinationInAppleMaps()
                    } label: {
                        Label("Apple Maps", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KronikuPalette.ink)

                    Button {
                        showsMapChooser = false
                        openSelectedDestinationInGoogleMaps()
                    } label: {
                        Label("Google Maps", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel", role: .cancel) {
                        showsMapChooser = false
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Spacer(minLength: 0)
                }
                .padding(20)
                .navigationTitle("Open in Maps")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Open linked memory", isPresented: $showsLinkedEventChooser, titleVisibility: .visible) {
            ForEach(linkedEvents) { linked in
                Button(linked.title ?? "Untitled") {
                    selectedLinkedEvent = linked
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose a related memory to open.")
        }
        .navigationDestination(item: $selectedLinkedEvent) { linked in
            ContactMomentDetailView(event: linked)
        }
    }

    private func fieldBlock<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interactionPicker: some View {
        HorizontalScrollHint {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Interaction.allCases) { item in
                        Button {
                            interaction = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(interaction == item ? KronikuPalette.paper : KronikuPalette.night)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    interaction == item
                                        ? AnyShapeStyle(KronikuPalette.heroGradient)
                                        : AnyShapeStyle(KronikuPalette.sand.opacity(0.92)),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var viewModeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            iconValueRow(systemImage: interaction.symbol, value: interaction.title)

            iconValueRow(systemImage: "calendar.badge.clock", value: timeRangeText)

            if !contactNames.isEmpty {
                iconValueRow(systemImage: "person.fill", value: contactNames.joined(separator: ", "))
            }

            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Note")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !linkedEvents.isEmpty {
                Button {
                    if linkedEvents.count == 1 {
                        selectedLinkedEvent = linkedEvents[0]
                    } else {
                        showsLinkedEventChooser = true
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Linked")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        HStack(spacing: 6) {
                            Text("\(linkedEvents.count) related event\(linkedEvents.count == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                                .underline()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }

            contextSummary

            if !photoAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow(title: "Photos", value: "\(photoAttachments.count)")
                    attachmentStrip
                }
            }
        }
    }

    private var editModeContent: some View {
        VStack(spacing: 12) {
            fieldBlock(title: "Type") {
                interactionPicker
            }

            fieldBlock(title: "Start Time") {
                DatePicker("Start time", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }

            fieldBlock(title: "End Time") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Has an end time", isOn: $hasEndTime)
                        .font(.subheadline)
                        .onChange(of: hasEndTime) { _, isOn in
                            endedAt = isOn ? max(occurredAt, endTimeDraft) : nil
                        }

                    DatePicker("End time", selection: $endTimeDraft, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .disabled(!hasEndTime)
                        .opacity(hasEndTime ? 1 : 0.35)
                        .onChange(of: endTimeDraft) { _, newValue in
                            guard hasEndTime else { return }
                            endedAt = newValue
                        }

                    if hasEndTime && !hasValidTimeRange {
                        Text("End time must be after the start time.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            fieldBlock(title: "Contacts") {
                VStack(alignment: .leading, spacing: 10) {
                    if !contactNames.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(contactNames, id: \.self) { name in
                                HStack(spacing: 4) {
                                    Text(name)
                                        .font(.caption.weight(.semibold))
                                    Button {
                                        contactNames.removeAll { $0 == name }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(KronikuPalette.sand, in: Capsule())
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Add a contact name", text: $contactNameInput)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .contactName)
                            .padding(12)
                            .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onSubmit { addContactName() }

                        Button {
                            addContactName()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                        }
                        .disabled(trimmedContactNameInput.isEmpty)
                    }
                }
            }

            fieldBlock(title: "Note") {
                TextEditor(text: $note)
                    .frame(minHeight: 130)
                    .focused($focusedField, equals: .note)
                    .padding(6)
                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Photos")
                    .font(.headline.weight(.semibold))
                    .fontDesign(.rounded)

                if contextController.consent.photoAttachmentEnabled {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                        Label(photoAttachments.isEmpty ? "Link photos" : "Update photos", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if !photoAttachments.isEmpty {
                        attachmentStrip
                    } else {
                        Text("No photos linked to this memory.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Photo attachments are disabled in settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if event.contactMoment != nil {
                Button(role: .destructive) { deleteBoth() } label: {
                    Label("Delete moment", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var contextSummary: some View {
        if hasContextDetails {
            VStack(alignment: .leading, spacing: 8) {
                if let place = preferredPlaceText {
                    iconValueButtonRow(systemImage: "mappin.and.ellipse", value: place, action: {
                        openMapChooser(query: place, coordinate: coordinate(for: event.place))
                    })
                }

                if let weather = preferredWeatherText {
                    iconValueRow(systemImage: "cloud.sun", value: weather)
                }

                if let motion = metadataByKey["motion"], !motion.isEmpty {
                    iconValueRow(systemImage: motionIcon(for: motion), value: motion.capitalized)
                }

                if let whenLabels = metadataByKey["timeSemantics"], !whenLabels.isEmpty {
                    iconValueRow(systemImage: "clock.badge.checkmark", value: whenLabels.replacingOccurrences(of: ",", with: " · "))
                }

                if let attendees = metadataByKey["attendees"], !attendees.isEmpty {
                    detailRow(title: "Attendees", value: attendees)
                }

                if let location = metadataByKey["location"], !location.isEmpty, preferredPlaceText == nil {
                    metadataRow(title: "Location", value: location, action: {
                        openMapChooser(query: location, coordinate: nil)
                    })
                }

                if let healthSummary = event.healthSummary, !healthSummary.entries.isEmpty {
                    ForEach(healthSummary.entries) { entry in
                        detailRow(title: entry.metric.title, value: entry.value)
                    }
                }

                ForEach(detailMetadata.filter { !["weather", "motion", "timeSemantics", "attendees", "location"].contains($0.key) }) { entry in
                    if !entry.value.isEmpty {
                        detailRow(title: displayTitle(for: entry.key), value: entry.value.replacingOccurrences(of: ",", with: " · "))
                    }
                }
            }
        }
    }

    private var hasContextDetails: Bool {
        preferredPlaceText != nil ||
        preferredWeatherText != nil ||
        (metadataByKey["motion"]?.isEmpty == false) ||
        (metadataByKey["timeSemantics"]?.isEmpty == false) ||
        (metadataByKey["attendees"]?.isEmpty == false) ||
        (metadataByKey["location"]?.isEmpty == false) ||
        (event.healthSummary?.entries.isEmpty == false) ||
        !detailMetadata.filter { !["weather", "motion", "timeSemantics", "attendees", "location"].contains($0.key) && !$0.value.isEmpty }.isEmpty
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
            return "\(condition), \(Int(temperatureC.rounded()))C"
        }
        if let weather = metadataByKey["weather"], !weather.isEmpty {
            return weather
        }
        return nil
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconValueRow(systemImage: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconValueButtonRow(systemImage: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.leading, 4)
            }
        }
        .buttonStyle(.plain)
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

    private func metadataValueRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capsuleValue(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(KronikuPalette.sand.opacity(0.92), in: Capsule())
    }

    @ViewBuilder
    private func metadataRow(title: String, value: String, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                metadataRowContent(title: title, value: value, isInteractive: true)
            }
            .buttonStyle(.plain)
        } else {
            metadataRowContent(title: title, value: value, isInteractive: false)
        }
    }

    private func metadataRowContent(title: String, value: String, isInteractive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(displayTitle(for: title))
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .foregroundStyle(isInteractive ? .blue : .secondary)
                .multilineTextAlignment(.trailing)
            if isInteractive {
                Image(systemName: "map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.leading, 4)
            }
        }
    }

    private func coordinate(for place: Place?) -> GeoCoordinate? {
        guard let latitude = place?.latitude, let longitude = place?.longitude else {
            return nil
        }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    private func openMapChooser(query: String, coordinate: GeoCoordinate?) {
        selectedMapDestination = MapDestination(query: query, coordinate: coordinate)
        showsMapChooser = true
    }

    private func openSelectedDestinationInAppleMaps() {
        guard let destination = selectedMapDestination,
              let url = appleMapsURL(for: destination) else { return }
        UIApplication.shared.open(url)
    }

    private func openSelectedDestinationInGoogleMaps() {
        guard let destination = selectedMapDestination else { return }
        guard let googleURL = googleMapsURL(for: destination),
              let webURL = googleMapsWebURL(for: destination) else { return }

        UIApplication.shared.open(googleURL, options: [:]) { success in
            if !success {
                UIApplication.shared.open(webURL)
            }
        }
    }

    private func appleMapsURL(for destination: MapDestination) -> URL? {
        if let coordinate = destination.coordinate {
            let encodedName = destination.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "http://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(encodedName)")
        }
        let encodedQuery = destination.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "http://maps.apple.com/?q=\(encodedQuery)")
    }

    private func googleMapsURL(for destination: MapDestination) -> URL? {
        if let coordinate = destination.coordinate {
            return URL(string: "comgooglemaps://?q=\(coordinate.latitude),\(coordinate.longitude)")
        }
        let encodedQuery = destination.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "comgooglemaps://?q=\(encodedQuery)")
    }

    private func googleMapsWebURL(for destination: MapDestination) -> URL? {
        if let coordinate = destination.coordinate {
            return URL(string: "https://www.google.com/maps/search/?api=1&query=\(coordinate.latitude),\(coordinate.longitude)")
        }
        let encodedQuery = destination.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/maps/search/?api=1&query=\(encodedQuery)")
    }

    private func displayTitle(for key: String) -> String {
        switch key {
        case "visit":
            return "Place"
        case "timeSemantics":
            return "When"
        default:
            return key.capitalized
        }
    }

    private func reloadFromEvent() {
        if let cm = event.contactMoment {
            contactNames = cm.contactNames.isEmpty ? [cm.personName].compactMap { $0 } : cm.contactNames
            note = cm.note
            interaction = Interaction(rawValue: cm.interactionType) ?? .moment
            occurredAt = cm.occurredAt
            endedAt = cm.endedAt
            hasEndTime = cm.endedAt != nil
            endTimeDraft = cm.endedAt ?? cm.occurredAt
        } else {
            contactNames = [event.detail].compactMap { $0 }.filter { !$0.isEmpty }
            note = event.title ?? ""
            interaction = .moment
            occurredAt = event.occurredAt ?? Date()
            endedAt = nil
            hasEndTime = false
        }
        contactNameInput = ""
        photoAttachments = event.photoAttachments
        selectedPhotoItems = []
    }

    private func addContactName() {
        let trimmed = trimmedContactNameInput
        guard !trimmed.isEmpty else { return }
        if !contactNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            contactNames.append(trimmed)
        }
        contactNameInput = ""
    }

    private func saveChanges() {
        let contactsMetadata: [ContextCard.MetadataEntry] = contactNames.isEmpty ? [] : [.init(key: "contacts", value: contactNames.joined(separator: ","))]
        let searchText = ([interaction.title] + contactNames).joined(separator: " ")

        if let cm = event.contactMoment {
            cm.contactNames = contactNames
            cm.personName = contactNames.first
            cm.note = note
            cm.interactionType = interaction.rawValue
            cm.occurredAt = occurredAt
            cm.endedAt = endedAt
            cm.updatedAt = Date()

            // keep MemoryEvent in sync
            event.occurredAt = occurredAt
            event.title = note
            event.detail = contactNames.isEmpty ? nil : contactNames.joined(separator: ", ")
            event.context = searchText
            let preservedMetadata = detailMetadata
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "moment",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: cm.interactionType),
                    .init(key: "captureMethod", value: cm.captureMethod)
                ] + contactsMetadata + preservedMetadata
            )
            event.symbolName = interaction.symbol
            event.photoAttachments = contextController.consent.photoAttachmentEnabled ? photoAttachments : []
            event.updatedAt = Date()
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
            } catch {
                print("Failed to save updates: \(error)")
            }
        } else {
            // create new contact moment and link it
            let cm = ContactMoment(personName: contactNames.first, interactionType: interaction.rawValue, occurredAt: occurredAt, endedAt: endedAt, note: note, captureMethod: "typed", contactNames: contactNames)
            cm.memoryEvent = event
            event.contactMoment = cm

            // update event fields
            event.occurredAt = occurredAt
            event.title = note
            event.detail = contactNames.isEmpty ? nil : contactNames.joined(separator: ", ")
            event.context = searchText
            let preservedMetadata = detailMetadata
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "moment",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: "typed")
                ] + contactsMetadata + preservedMetadata
            )
            event.symbolName = interaction.symbol
            event.photoAttachments = contextController.consent.photoAttachmentEnabled ? photoAttachments : []
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil

            modelContext.insert(cm)

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
            } catch {
                print("Failed to create contact moment: \(error)")
            }
        }

        dismiss()
    }

    private func deleteBoth() {
        // delete the contact moment and the event
        if let cm = event.contactMoment {
            modelContext.delete(cm)
        }
        modelContext.delete(event)
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
        } catch {
            print("Failed to delete: \(error)")
        }
        dismiss()
    }

    private var attachmentStrip: some View {
        HorizontalScrollHint {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(photoAttachments) { attachment in
                        ZStack(alignment: .topTrailing) {
                            attachmentThumbnail(attachment)

                            Button {
                                photoAttachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.75))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func attachmentThumbnail(_ attachment: PhotoAttachment) -> some View {
        PhotoAttachmentThumbnail(attachment: attachment, size: CGSize(width: 92, height: 92))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadPhotoAttachments(from items: [PhotosPickerItem]) async {
        var newAttachments = photoAttachments
        for item in items {
            guard let assetIdentifier = item.itemIdentifier else { continue }
            let attachment = PhotoAttachment(assetIdentifier: assetIdentifier, filename: assetIdentifier)
            if !newAttachments.contains(where: { $0.assetIdentifier == assetIdentifier }) {
                newAttachments.append(attachment)
            }
        }
        photoAttachments = newAttachments
    }
}
