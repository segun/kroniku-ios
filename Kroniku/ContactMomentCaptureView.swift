import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ContactMomentCaptureView: View {
    private enum FocusField: Hashable {
        case contactName, note, sharedNote, voiceTranscript
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @EnvironmentObject private var tier2Controller: Tier2ContextController
    @Query(sort: \MemoryEvent.occurredAt, order: .reverse) private var existingEvents: [MemoryEvent]
    @FocusState private var focusedField: FocusField?

    @State private var note = ""
    @State private var sharedNote = ""
    @State private var interaction: Interaction = .moment
    @State private var contactNameInput = ""
    @State private var contactNames: [String] = []
    @State private var isListening = false
    @State private var voiceTranscript = ""
    @State private var transcriptionResult: Tier2TranscriptionResult?
    @State private var didApplyVoiceDetails = false
    @State private var resolvedContactIdentifiers: [String: String] = [:]
    @State private var resolvingContactName: String?
    @State private var pendingContactResolutionQueue: [String] = []
    @State private var resolutionCandidates: [Tier2ResolvedPerson] = []
    @State private var isShowingResolutionPicker = false
    @State private var resolutionStatusMessage: String?
    @State private var capturedBluetoothContext: BluetoothContextKind?
    @State private var linkedEventIDs: Set<UUID> = []
    @State private var voiceErrorMessage: String?
    @State private var startTime = Date()
    @State private var endTime: Date?
    @State private var hasEndTime = false
    @State private var includeHealthData = false
    // Kept mounted at all times so the DatePicker is never destroyed/recreated, which crashes on some iOS versions.
    @State private var endTimeDraft = Date()
    @State private var saveErrorMessage: String?
    @State private var isSaving = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAttachments: [PhotoAttachment] = []
    @State private var manualEntryShown = false

    init(prelinkedEventIDs: Set<UUID> = []) {
        _linkedEventIDs = State(initialValue: prelinkedEventIDs)
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedContactNameInput: String {
        contactNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSharedNote: String {
        sharedNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasValidTimeRange: Bool {
        guard let endTime else { return true }
        return endTime >= startTime
    }

    private var canSave: Bool {
        let hasContent = !(trimmedNote.isEmpty && contactNames.isEmpty && voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return hasContent && hasValidTimeRange
    }


    private var canUseVoiceFlow: Bool {
        contextController.consent.voiceTranscriptionEnabled
    }

    private var shouldShowVoiceCaptureSection: Bool {
        canUseVoiceFlow && (isListening || (!voiceTranscript.isEmpty && !didApplyVoiceDetails))
    }

    private var shouldShowEditableDetails: Bool {
        !canUseVoiceFlow || manualEntryShown || didApplyVoiceDetails
    }

    private var linkableEvents: [MemoryEvent] {
        existingEvents.filter { event in
            guard event.source != "calendar" else { return false }
            guard let title = event.title, !title.isEmpty else { return false }
            return true
        }
        .prefix(8)
        .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KronikuPalette.canvasGradient
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Button {
                                    focusedField = nil
                                    Task {
                                        await toggleVoiceRecording()
                                    }
                                } label: {
                                    Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                                        .font(.system(size: 48, weight: .semibold))
                                        .foregroundStyle(KronikuPalette.paper)
                                        .frame(width: 76, height: 76)
                                        .background(
                                            isListening
                                            ? LinearGradient(colors: [Color.red, Color.red.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            : KronikuPalette.emberGradient,
                                            in: Circle()
                                        )
                                        .symbolEffect(.pulse, isActive: isListening)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canUseVoiceFlow)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isListening ? "Recording" : "Record a moment")
                                        .font(.title2.weight(.bold))
                                        .fontDesign(.rounded)
                                        .foregroundStyle(KronikuPalette.ink)
                                    Text(
                                        isListening
                                        ? "Tap to stop recording"
                                        : (canUseVoiceFlow ? "Capture first, refine second." : "Turn on spoken notes in Settings.")
                                    )
                                        .font(.subheadline)
                                        .foregroundStyle(KronikuPalette.night.opacity(0.72))
                                }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 4)

                        VStack(spacing: 14) {
                            if canUseVoiceFlow {
                                Button {
                                    manualEntryShown.toggle()
                                } label: {
                                    Label(manualEntryShown ? "Use voice instead" : "Type instead", systemImage: manualEntryShown ? "mic" : "keyboard")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            if shouldShowVoiceCaptureSection {
                                voiceCaptureSection
                            }

                            if shouldShowEditableDetails {
                                formField(title: "Type") {
                                    interactionPicker
                                }

                                formField(title: "What happened") {
                                    TextField("e.g. Went for a run between 12am and 3am", text: $note, axis: .vertical)
                                        .lineLimit(3...6)
                                        .textFieldStyle(.plain)
                                        .focused($focusedField, equals: .note)
                                        .padding(12)
                                        .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                formField(title: "Start Time") {
                                    DatePicker("Start time", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                formField(title: "End Time") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Toggle("Has an end time", isOn: $hasEndTime)
                                            .font(.subheadline)
                                            .onChange(of: hasEndTime) { _, isOn in
                                                endTime = isOn ? max(startTime, endTimeDraft) : nil
                                            }

                                        DatePicker("End time", selection: $endTimeDraft, displayedComponents: [.date, .hourAndMinute])
                                            .labelsHidden()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .disabled(!hasEndTime)
                                            .opacity(hasEndTime ? 1 : 0.35)
                                            .onChange(of: endTimeDraft) { _, newValue in
                                                guard hasEndTime else { return }
                                                endTime = newValue
                                            }

                                        if hasEndTime && !hasValidTimeRange {
                                            Text("End time must be after the start time.")
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }

                                Toggle("Include health data", isOn: $includeHealthData)
                                    .font(.subheadline)
                                    .tint(KronikuPalette.ink)

                                if contextController.consent.noteIngestionEnabled {
                                    formField(title: "Shared note") {
                                        ZStack(alignment: .topLeading) {
                                            if trimmedSharedNote.isEmpty {
                                                Text("Add a note or detail to keep with this memory…")
                                                    .font(.body)
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 14)
                                            }
                                            TextEditor(text: $sharedNote)
                                                .frame(minHeight: 92)
                                                .focused($focusedField, equals: .sharedNote)
                                                .padding(6)
                                        }
                                        .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                        if !linkableEvents.isEmpty {
                                            Text("Link this note to existing memories")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            Menu {
                                                ForEach(linkableEvents) { event in
                                                    Button {
                                                        if linkedEventIDs.contains(event.id) {
                                                            linkedEventIDs.remove(event.id)
                                                        } else {
                                                            linkedEventIDs.insert(event.id)
                                                        }
                                                    } label: {
                                                        let isSelected = linkedEventIDs.contains(event.id)
                                                        let timestamp = (event.occurredAt ?? Date()).formatted(.dateTime.month().day().hour().minute())
                                                        Label("\(event.title ?? "Untitled") - \(timestamp)", systemImage: isSelected ? "checkmark" : "circle")
                                                    }
                                                }
                                            } label: {
                                                Label(
                                                    linkedEventIDs.isEmpty
                                                        ? "Select related memories"
                                                        : "\(linkedEventIDs.count) memories linked",
                                                    systemImage: "chevron.down.circle"
                                                )
                                                .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }

                                formField(title: "Attachments") {
                                    if contextController.consent.photoAttachmentEnabled {
                                        VStack(alignment: .leading, spacing: 10) {
                                            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                                                Label(photoAttachments.isEmpty ? "Link photos" : "Update photos", systemImage: "photo.on.rectangle.angled")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.bordered)

                                            if !photoAttachments.isEmpty {
                                                attachmentStrip
                                            }
                                        }
                                    } else {
                                        Text("Enable photo attachments in settings to link images to this memory.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                formField(title: "Contacts") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Link zero or more people to this moment.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        if !contactNames.isEmpty {
                                            contactChipStrip
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
                            }
                        }
                        .kronikuCard()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Moment")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { focusedField = nil; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isListening ? "Continue" : "Save") {
                        focusedField = nil
                        Task { await continueOrSave() }
                    }
                        .fontWeight(.semibold)
                        .disabled((!isListening && !canSave) || isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .alert("Could not save moment", isPresented: Binding(get: { saveErrorMessage != nil }, set: { isPresented in
            if !isPresented {
                saveErrorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Unknown error")
        }
        .alert("Voice capture", isPresented: Binding(get: { voiceErrorMessage != nil }, set: { isPresented in
            if !isPresented {
                voiceErrorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voiceErrorMessage ?? "Unknown voice error")
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadPhotoAttachments(from: newItems)
            }
        }
        .confirmationDialog(
            "Choose contact",
            isPresented: $isShowingResolutionPicker,
            titleVisibility: .visible
        ) {
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
        .onDisappear {
            if isListening {
                Task {
                    _ = await tier2Controller.stopRecording()
                }
            }
        }
    }

    private var voiceCaptureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isListening {
                Label("Listening… tap the microphone again to stop", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !voiceTranscript.isEmpty {
                TextEditor(text: $voiceTranscript)
                    .frame(minHeight: 88)
                    .focused($focusedField, equals: .voiceTranscript)
                    .padding(6)
                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(isListening)

                if !isListening {
                    Button {
                        focusedField = nil
                        Task {
                            if await extractFromTranscript() {
                                didApplyVoiceDetails = true
                                voiceTranscript = ""
                            }
                        }
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(KronikuPalette.ink)
                }
            }
        }
    }

    private func formField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func saveContactMoment() async {
        isSaving = true
        defer { isSaving = false }

        if isListening {
            _ = await tier2Controller.stopRecording()
            isListening = false
        }

        let transcriptText = voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryNote = trimmedNote.isEmpty ? transcriptText : trimmedNote
        let mergedNote: String
        if trimmedSharedNote.isEmpty {
            mergedNote = primaryNote
        } else if primaryNote.isEmpty {
            mergedNote = "Shared note: \(trimmedSharedNote)"
        } else {
            mergedNote = "\(primaryNote)\n\nShared note: \(trimmedSharedNote)"
        }

        let extractionReview: Tier2ExtractionReview?
        if let transcriptionResult {
            extractionReview = Tier2ExtractionReview(
                transcript: transcriptionResult.transcript,
                extractedPersonName: transcriptionResult.extractedPersonName,
                extractedInteractionType: transcriptionResult.extractedInteraction?.rawValue,
                extractedOccurredAt: transcriptionResult.extractedOccurredAt,
                confidence: transcriptionResult.confidence
            )
        } else {
            extractionReview = nil
        }

        if contextController.consent.bluetoothContextEnabled {
            capturedBluetoothContext = await tier2Controller.captureBluetoothContext()
        }

        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        do {
            let enrichment = await contextController.buildEnrichment(for: startTime, includeHealthData: includeHealthData)
            try repo.addContactMoment(
                personName: nil,
                interactionType: interaction.rawValue,
                occurredAt: startTime,
                note: mergedNote,
                contextEnrichment: enrichment,
                photoAttachments: photoAttachments,
                resolvedContactIdentifier: nil,
                extractionReview: extractionReview,
                bluetoothContext: capturedBluetoothContext,
                confidenceScore: extractionReview?.confidence.overall,
                linkedEventIDs: Array(linkedEventIDs),
                contactNames: contactNames,
                resolvedContactIdentifiers: contactNames.compactMap { resolvedContactIdentifiers[$0] },
                endedAt: endTime,
                includeHealthData: includeHealthData
            )
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func continueOrSave() async {
        if isListening {
            voiceTranscript = await tier2Controller.stopRecording()
            isListening = false

            guard await extractFromTranscript() else {
                return
            }
            didApplyVoiceDetails = true
            voiceTranscript = ""
            return
        }

        await saveContactMoment()
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
        var attachments: [PhotoAttachment] = []
        for item in items {
            guard let assetIdentifier = item.itemIdentifier else { continue }
            attachments.append(
                PhotoAttachment(assetIdentifier: assetIdentifier, filename: assetIdentifier)
            )
        }
        photoAttachments = attachments
    }

    private func toggleVoiceRecording() async {
        guard canUseVoiceFlow else {
            voiceErrorMessage = "Turn on spoken notes in Settings first."
            return
        }

        if !isListening {
            didApplyVoiceDetails = false
            transcriptionResult = nil
            if tier2Controller.microphonePermission != .authorized {
                await tier2Controller.requestMicrophonePermission()
            }
            if tier2Controller.speechPermission != .authorized {
                await tier2Controller.requestSpeechPermission()
            }
            guard tier2Controller.microphonePermission == .authorized,
                  tier2Controller.speechPermission == .authorized else {
                voiceErrorMessage = "Allow microphone and speech permissions to record voice moments."
                return
            }

            do {
                try await tier2Controller.startRecording { partialTranscript in
                    voiceTranscript = partialTranscript
                }
                isListening = true
            } catch {
                voiceErrorMessage = error.localizedDescription
            }
        } else {
            voiceTranscript = await tier2Controller.stopRecording()
            isListening = false
        }
    }

    private func extractFromTranscript() async -> Bool {
        guard let result = await tier2Controller.transcribe(voiceTranscript) else {
            transcriptionResult = nil
            return false
        }
        transcriptionResult = result
        applyExtraction(result)
        return true
    }

    private func applyExtraction(_ result: Tier2TranscriptionResult) {
        if let extractedPersonName = result.extractedPersonName {
            let trimmed = extractedPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !contactNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                contactNames.append(trimmed)
            }
        }
        if let extractedInteraction = result.extractedInteraction {
            interaction = extractedInteraction
        }
        if let extractedOccurredAt = result.extractedOccurredAt {
            startTime = extractedOccurredAt
        }
        if trimmedNote.isEmpty {
            note = result.transcript
        }
    }

    private func addContactName() {
        let trimmed = trimmedContactNameInput
        guard !trimmed.isEmpty else { return }
        if !contactNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            contactNames.append(trimmed)
        }
        contactNameInput = ""
    }

    private func removeContactName(_ name: String) {
        contactNames.removeAll { $0 == name }
        resolvedContactIdentifiers[name] = nil
    }

    private var contactChipStrip: some View {
        HorizontalScrollHint {
            ScrollView(.horizontal, showsIndicators: false) {
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
                                removeContactName(name)
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
                .padding(.vertical, 2)
            }
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

    // Walks the queue automatically, only pausing to surface a picker when a name has multiple matches.
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
}
