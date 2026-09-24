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
    @EnvironmentObject private var tier2Controller: Tier2ContextController
    @Query(sort: \MemoryEvent.occurredAt, order: .reverse) private var allEvents: [MemoryEvent]
    @FocusState private var focusedField: FocusField?

    let event: MemoryEvent

    @State private var contactNames: [String] = []
    @State private var contactNameInput: String = ""
    @State private var resolvedContactIdentifiers: [String: String] = [:]
    @State private var resolvingContactName: String?
    @State private var pendingContactResolutionQueue: [String] = []
    @State private var resolutionCandidates: [Tier2ResolvedPerson] = []
    @State private var isShowingResolutionPicker = false
    @State private var resolutionStatusMessage: String?
    @State private var note: String = ""
    @State private var weatherCondition: String = ""
    @State private var weatherTemperature: String = ""
    @State private var interaction: Interaction = .moment
    @State private var occurredAt: Date = Date()
    @State private var endedAt: Date?
    @State private var hasEndTime = false
    @State private var includeHealthData = false
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
            !(entry.key == "interactionType" || entry.key == "captureMethod" || entry.key == "visit" || entry.key == "contacts" || entry.key == "userNote" || entry.key == "endedAt")
        }
    }

    private var trimmedContactNameInput: String {
        contactNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isContactMoment: Bool {
        event.source == "contactMoment" || event.contactMoment != nil
    }

    private var eventKindTitle: String {
        switch event.source {
        case "workout": return "Workout"
        case "trip": return event.title == "Stop" ? "Stop" : "Trip"
        case "calendar": return "Calendar event"
        case "contactMoment": return "Memory"
        case "geofence": return event.title ?? "Place"
        default: return "Event"
        }
    }

    private var eventKindSubtitle: String {
        switch event.source {
        case "workout": return "Health activity"
        case "trip": return "Motion and location"
        case "calendar": return "Imported calendar details"
        case "contactMoment": return isEditing ? "Edit" : "Details"
        case "geofence": return "Saved place"
        default: return "Details"
        }
    }

    private var hasValidTimeRange: Bool {
        guard let endedAt else { return true }
        return endedAt >= occurredAt
    }

    private var canSaveEdits: Bool {
        if !isContactMoment {
            return weatherTemperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedTemperature != nil
        }
        let hasContent = !(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contactNames.isEmpty)
        return hasContent && hasValidTimeRange
    }

    private var parsedTemperature: Double? {
        Double(weatherTemperature.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
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

    init(event: MemoryEvent, startsInEditMode: Bool = false) {
        self.event = event
        _isEditing = State(initialValue: startsInEditMode)
        // initialize states from linked contact moment if available
        if let cm = event.contactMoment {
            let names = cm.contactNames.isEmpty ? [cm.personName].compactMap { $0 } : cm.contactNames
            var resolvedIdentifiers: [String: String] = [:]
            for (name, identifier) in zip(names, cm.resolvedContactIdentifiers) {
                resolvedIdentifiers[name] = identifier
            }
            _contactNames = State(initialValue: names)
            _resolvedContactIdentifiers = State(initialValue: resolvedIdentifiers)
            _note = State(initialValue: cm.note)
            _interaction = State(initialValue: Interaction(rawValue: cm.interactionType) ?? .moment)
            _occurredAt = State(initialValue: cm.occurredAt)
            _endedAt = State(initialValue: cm.endedAt)
            _hasEndTime = State(initialValue: cm.endedAt != nil)
            _endTimeDraft = State(initialValue: cm.endedAt ?? cm.occurredAt)
            _includeHealthData = State(initialValue: event.includeHealthData)
        } else if event.source == "contactMoment" {
            _contactNames = State(initialValue: [event.detail].compactMap { $0 }.filter { !$0.isEmpty })
            _note = State(initialValue: event.title ?? "")
            _occurredAt = State(initialValue: event.occurredAt ?? Date())
            _includeHealthData = State(initialValue: event.includeHealthData)
        } else {
            let metadata = Dictionary(
                (event.contextCard?.metadata ?? []).map { ($0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            _contactNames = State(initialValue: metadata["contacts"]?.split(separator: ",").map(String.init) ?? [])
            _note = State(initialValue: metadata["userNote"] ?? "")
            _occurredAt = State(initialValue: event.occurredAt ?? Date())
            _endedAt = State(initialValue: event.derivedEndedAt)
            _hasEndTime = State(initialValue: event.derivedEndedAt != nil)
            _endTimeDraft = State(initialValue: event.derivedEndedAt ?? event.occurredAt ?? Date())
            _includeHealthData = State(initialValue: event.includeHealthData)
        }
        _weatherCondition = State(initialValue: event.weatherSnapshot?.condition ?? "")
        _weatherTemperature = State(initialValue: event.weatherSnapshot?.temperatureC.map { String(format: "%.1f", $0) } ?? "")
        _photoAttachments = State(initialValue: event.photoAttachments)
    }

    var body: some View {
        ZStack {
            KronikuPalette.canvasGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(eventKindTitle)
                            .font(.title2.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(KronikuPalette.paper)
                        Text(eventKindSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(KronikuPalette.fog)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if isContactMoment {
                        Group {
                            if isEditing {
                                editModeContent
                            } else {
                                viewModeContent
                            }
                        }
                        .kronikuCard()
                    } else {
                        Group {
                            if isEditing {
                                systemEventEditContent
                            } else {
                                systemEventContent
                            }
                        }
                        .kronikuCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .navigationTitle(eventKindTitle)
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
        .confirmationDialog("Choose contact", isPresented: $isShowingResolutionPicker, titleVisibility: .visible) {
            ForEach(resolutionCandidates, id: \.identifier) { candidate in
                Button {
                    applyResolvedContact(candidate)
                } label: {
                    if let hint = candidate.disambiguationHint, !hint.isEmpty {
                        Text("\(candidate.displayName) - \(hint)")
                    } else {
                        Text(candidate.displayName)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                resolutionStatusMessage = "No contact selected for \(resolvingContactName ?? "that name")."
                resolvingContactName = nil
                Task {
                    await processNextPendingContactResolution()
                }
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

    private var systemEventContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = event.title, !title.isEmpty {
                iconValueRow(systemImage: event.symbolName ?? systemEventIcon, value: title)
            }

            iconValueRow(systemImage: "calendar.badge.clock", value: systemEventTimeRangeText)

            if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                detailRow(title: systemEventDetailLabel, value: detail)
            }

            if let media = event.contextCard?.metadata.first(where: { $0.key == "mediaNowPlaying" })?.value {
                detailRow(title: "Now playing", value: media)
            }

            if !contactNames.isEmpty {
                detailRow(title: "People", value: contactNames.joined(separator: ", "))
            }

            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detailRow(title: "Note", value: note)
            }

            if let route = event.workoutRoute, !route.coordinates.isEmpty {
                WorkoutRouteMapView(coordinates: route.coordinates)
            }

            contextSummary

            if !linkedEvents.isEmpty {
                detailRow(title: "Related", value: "\(linkedEvents.count) event\(linkedEvents.count == 1 ? "" : "s")")
            }
        }
    }

    private var systemEventEditContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title = event.title, !title.isEmpty {
                iconValueRow(systemImage: event.symbolName ?? systemEventIcon, value: title)
            }
            iconValueRow(systemImage: "calendar.badge.clock", value: systemEventTimeRangeText)
            if let detail = event.detail, !detail.isEmpty {
                detailRow(title: systemEventDetailLabel, value: detail)
            }

            peopleEditField

            fieldBlock(title: "What happened") {
                TextEditor(text: $note)
                    .frame(minHeight: 120)
                    .focused($focusedField, equals: .note)
                    .padding(6)
                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            weatherEditFields

            if contextController.consent.photoAttachmentEnabled {
                fieldBlock(title: "Photos") {
                    PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                        Label(photoAttachments.isEmpty ? "Link photos" : "Update photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    if !photoAttachments.isEmpty { attachmentStrip }
                }
            }
        }
    }

    private var peopleEditField: some View {
        fieldBlock(title: "People") {
            VStack(alignment: .leading, spacing: 10) {
                if !contactNames.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(contactNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Text(name).font(.caption.weight(.semibold))
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
                    TextField("Add a person", text: $contactNameInput)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .contactName)
                        .padding(12)
                        .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onSubmit { addContactName() }
                    Button { addContactName() } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .disabled(trimmedContactNameInput.isEmpty)
                }
            }
        }
    }

    private var weatherEditFields: some View {
        fieldBlock(title: "Weather") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Condition, e.g. Partly cloudy", text: $weatherCondition)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    TextField("Temperature", text: $weatherTemperature)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                    Text("°C").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !weatherTemperature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedTemperature == nil {
                    Text("Enter a valid temperature.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var systemEventIcon: String {
        switch event.source {
        case "workout": return "figure.walk"
        case "trip": return event.title?.hasPrefix("Arrived at ") == true ? "mappin.and.ellipse" : "car"
        case "calendar": return "calendar"
        default: return "circle.dotted"
        }
    }

    private var systemEventTimeRangeText: String {
        guard let start = event.occurredAt else { return "Time unavailable" }
        let startText = start.formatted(.dateTime.weekday().month().day().hour().minute())
        guard let end = event.derivedEndedAt else { return startText }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(startText) - \(end.formatted(.dateTime.hour().minute()))"
        }
        return "\(startText) - \(end.formatted(.dateTime.weekday().month().day().hour().minute()))"
    }

    private var systemEventDetailLabel: String {
        if event.source == "workout" { return "Duration" }
        if event.source == "trip", event.title == "Stop" { return "Location and duration" }
        if event.source == "trip" { return "Route" }
        return "Details"
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

            if isContactMoment {
                Toggle("Include health data", isOn: $includeHealthData)
                    .font(.subheadline)
                    .tint(KronikuPalette.ink)
            }

            fieldBlock(title: "Contacts") {
                VStack(alignment: .leading, spacing: 10) {
                    if !contactNames.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(contactNames, id: \.self) { name in
                                HStack(spacing: 4) {
                                    if resolvedContactIdentifiers[name] != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                    }
                                    Text(name)
                                        .font(.caption.weight(.semibold))
                                    Button {
                                        contactNames.removeAll { $0 == name }
                                        resolvedContactIdentifiers[name] = nil
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

                    if contextController.consent.contactsResolutionEnabled {
                        Button {
                            focusedField = nil
                            Task {
                                await resolveContactsFromContactsApp()
                            }
                        } label: {
                            Label("Match with Contacts", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(contactNames.isEmpty)
                    }

                    if let resolutionStatusMessage {
                        Text(resolutionStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

            weatherEditFields

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
        case "unknown": return "questionmark.circle"
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
            contactNames = metadataByKey["contacts"]?.split(separator: ",").map(String.init) ?? []
            note = metadataByKey["userNote"] ?? ""
            interaction = .moment
            occurredAt = event.occurredAt ?? Date()
            endedAt = event.derivedEndedAt
            hasEndTime = event.derivedEndedAt != nil
        }
        weatherCondition = event.weatherSnapshot?.condition ?? ""
        weatherTemperature = event.weatherSnapshot?.temperatureC.map { String(format: "%.1f", $0) } ?? ""
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
            cm.resolvedContactIdentifiers = contactNames.compactMap { resolvedContactIdentifiers[$0] }
            cm.updatedAt = Date()

            // keep MemoryEvent in sync
            event.occurredAt = occurredAt
            event.source = "contactMoment"
            event.title = note
            event.detail = contactNames.isEmpty ? nil : contactNames.joined(separator: ", ")
            event.context = searchText
            let preservedMetadata = detailMetadata.filter { $0.key != "includeHealthData" }
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "moment",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: cm.interactionType),
                    .init(key: "captureMethod", value: cm.captureMethod)
                ] + contactsMetadata + [.init(key: "includeHealthData", value: String(includeHealthData))] + preservedMetadata
            )
            event.symbolName = interaction.symbol
            event.includeHealthData = includeHealthData
            event.healthSummary = includeHealthData ? event.healthSummary : nil
            event.photoAttachments = contextController.consent.photoAttachmentEnabled ? photoAttachments : []
            event.updatedAt = Date()
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil

            applyEditedWeather()

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
            } catch {
                print("Failed to save updates: \(error)")
            }
        } else {
            var metadata = event.contextCard?.metadata ?? []
            metadata.removeAll { $0.key == "userNote" || $0.key == "contacts" }
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNote.isEmpty {
                metadata.append(.init(key: "userNote", value: trimmedNote))
            }
            if !contactNames.isEmpty {
                metadata.append(.init(key: "contacts", value: contactNames.joined(separator: ",")))
            }
            var card = event.contextCard ?? ContextCard(
                source: event.source ?? "derived",
                category: "derived",
                summary: event.detail ?? event.title ?? "Activity"
            )
            card.metadata = metadata
            event.contextCard = card
            event.context = ([event.title, trimmedNote] + contactNames).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            event.photoAttachments = contextController.consent.photoAttachmentEnabled ? photoAttachments : []
            event.includeHealthData = event.source == "workout" || event.source == "sleep"
            applyEditedWeather()
            event.updatedAt = Date()
            event.backendVersion = max(1, event.backendVersion + 1)
            event.syncedToBackendAt = nil

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
            } catch {
                print("Failed to save activity context: \(error)")
            }
        }

        dismiss()
    }

    private func applyEditedWeather() {
        let condition = weatherCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        let temperature = parsedTemperature
        guard !condition.isEmpty || temperature != nil else {
            event.weatherSnapshot = nil
            return
        }
        if let weather = event.weatherSnapshot {
            weather.condition = condition.isEmpty ? nil : condition
            weather.temperatureC = temperature
            weather.observedAt = event.occurredAt ?? Date()
        } else {
            event.weatherSnapshot = WeatherSnapshot(
                observedAt: event.occurredAt ?? Date(),
                condition: condition.isEmpty ? nil : condition,
                temperatureC: temperature
            )
        }
    }

    private func resolveContactsFromContactsApp() async {
        guard contextController.consent.contactsResolutionEnabled else { return }

        if tier2Controller.contactsPermission == .notDetermined {
            await tier2Controller.requestContactsPermission()
        }
        guard tier2Controller.contactsPermission == .authorized else {
            resolutionStatusMessage = "Contacts permission is required to match people."
            return
        }

        pendingContactResolutionQueue = contactNames.filter { resolvedContactIdentifiers[$0] == nil }
        await processNextPendingContactResolution()
    }

    private func processNextPendingContactResolution() async {
        guard !pendingContactResolutionQueue.isEmpty else {
            resolutionStatusMessage = "Matched contacts where possible."
            return
        }

        let name = pendingContactResolutionQueue.removeFirst()
        guard resolvedContactIdentifiers[name] == nil else {
            await processNextPendingContactResolution()
            return
        }

        let matches = await tier2Controller.resolvePeople(named: name, limit: 5)
        if matches.isEmpty {
            await processNextPendingContactResolution()
            return
        }
        if matches.count == 1, let only = matches.first {
            resolvedContactIdentifiers[name] = only.identifier
            await processNextPendingContactResolution()
            return
        }

        resolvingContactName = name
        resolutionCandidates = matches
        isShowingResolutionPicker = true
        resolutionStatusMessage = "Multiple matches for \(name). Choose one."
    }

    private func applyResolvedContact(_ person: Tier2ResolvedPerson) {
        if let name = resolvingContactName {
            resolvedContactIdentifiers[name] = person.identifier
        }
        resolvingContactName = nil
        resolutionStatusMessage = "Matched from your contacts."
        Task {
            await processNextPendingContactResolution()
        }
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

import MapKit

private struct WorkoutRouteMapView: View {
    let coordinates: [GeoCoordinate]

    private var region: MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.4),
            longitudeDelta: max(0.005, (lons.max()! - lons.min()!) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    var body: some View {
        Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                .stroke(KronikuPalette.ember, lineWidth: 3)
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}
