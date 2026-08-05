import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ContactMomentCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @EnvironmentObject private var tier2Controller: Tier2ContextController
    @Query(sort: \MemoryEvent.occurredAt, order: .reverse) private var existingEvents: [MemoryEvent]

    @State private var note = ""
    @State private var sharedNote = ""
    @State private var personName = ""
    @State private var interaction = Interaction.call
    @State private var isListening = false
    @State private var voiceTranscript = ""
    @State private var transcriptionResult: Tier2TranscriptionResult?
    @State private var didApplyVoiceDetails = false
    @State private var resolvedPerson: Tier2ResolvedPerson?
    @State private var capturedBluetoothContext: BluetoothContextKind?
    @State private var linkedEventIDs: Set<UUID> = []
    @State private var voiceErrorMessage: String?
    @State private var occurredAt = Date()
    @State private var saveErrorMessage: String?
    @State private var isSaving = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoAttachments: [PhotoAttachment] = []

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPersonName: String {
        personName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSharedNote: String {
        sharedNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !(trimmedNote.isEmpty && trimmedPersonName.isEmpty && voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var canUseVoiceFlow: Bool {
        contextController.consent.voiceTranscriptionEnabled
    }

    private var shouldShowVoiceCaptureSection: Bool {
        canUseVoiceFlow && (isListening || (!voiceTranscript.isEmpty && !didApplyVoiceDetails))
    }

    private var shouldShowEditableDetails: Bool {
        !isListening && (voiceTranscript.isEmpty || didApplyVoiceDetails)
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
                            KronikuLogoRow(subtitle: "Capture")

                            HStack(spacing: 12) {
                                Button {
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
                                        .foregroundStyle(KronikuPalette.paper)
                                    Text(
                                        isListening
                                        ? "Tap to stop recording"
                                        : (canUseVoiceFlow ? "Capture first, refine second." : "Enable voice transcription in Settings.")
                                    )
                                        .font(.subheadline)
                                        .foregroundStyle(KronikuPalette.fog)
                                }
                                Spacer()
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KronikuPalette.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                        VStack(spacing: 14) {
                            if shouldShowVoiceCaptureSection {
                                voiceCaptureSection
                            }

                            if shouldShowEditableDetails {
                                Picker("Interaction", selection: $interaction) {
                                    ForEach(Interaction.allCases) { item in
                                        Label(item.title, systemImage: item.symbol).tag(item)
                                    }
                                }
                                .pickerStyle(.segmented)

                                formField(title: "Who") {
                                    TextField("Person name (optional)", text: $personName)
                                        .textFieldStyle(.plain)
                                        .padding(12)
                                        .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                formField(title: "What happened") {
                                    TextField("e.g. Called Mr. Kroenke about the contract", text: $note, axis: .vertical)
                                        .lineLimit(3...6)
                                        .textFieldStyle(.plain)
                                        .padding(12)
                                        .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }

                                if contextController.consent.noteIngestionEnabled {
                                    formField(title: "Shared note") {
                                        TextEditor(text: $sharedNote)
                                            .frame(minHeight: 92)
                                            .padding(6)
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

                                formField(title: "When") {
                                    DatePicker("Occurred at", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                formField(title: "Attachments") {
                                    if contextController.consent.photoAttachmentEnabled {
                                        VStack(alignment: .leading, spacing: 10) {
                                            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 6, matching: .images) {
                                                Label(photoAttachments.isEmpty ? "Link photos" : "Update photos", systemImage: "photo.on.rectangle.angled")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(KronikuPalette.ember)

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

                                if contextController.consent.contactsResolutionEnabled {
                                    formField(title: "Contacts resolution") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Resolve person names with your contacts only when you choose.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            Button {
                                                Task {
                                                    await resolvePersonFromContacts()
                                                }
                                            } label: {
                                                Label("Resolve person", systemImage: "person.crop.circle.badge.checkmark")
                                                    .frame(maxWidth: .infinity)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(KronikuPalette.ember)
                                            .disabled(trimmedPersonName.isEmpty)

                                            if let resolvedPerson {
                                                Text("Matched: \(resolvedPerson.displayName)")
                                                    .font(.subheadline)
                                            }
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
            .navigationTitle("Contact moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveContactMoment() }
                    }
                        .fontWeight(.semibold)
                        .disabled(!canSave || isSaving)
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
                    .padding(6)
                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(isListening)

                if !isListening {
                    Button {
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

        if contextController.consent.contactsResolutionEnabled,
           resolvedPerson == nil,
           !trimmedPersonName.isEmpty {
            await resolvePersonFromContacts()
        }

        if contextController.consent.bluetoothContextEnabled {
            capturedBluetoothContext = await tier2Controller.captureBluetoothContext()
        }

        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        do {
            let enrichment = await contextController.buildEnrichment(for: occurredAt)
            try repo.addContactMoment(
                personName: trimmedPersonName,
                interactionType: interaction.rawValue,
                occurredAt: occurredAt,
                note: mergedNote,
                contextEnrichment: enrichment,
                photoAttachments: photoAttachments,
                resolvedContactIdentifier: resolvedPerson?.identifier,
                extractionReview: extractionReview,
                bluetoothContext: capturedBluetoothContext,
                confidenceScore: extractionReview?.confidence.overall,
                linkedEventIDs: Array(linkedEventIDs)
            )
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private var attachmentStrip: some View {
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

    private func attachmentThumbnail(_ attachment: PhotoAttachment) -> some View {
        Group {
            if let uiImage = UIImage(data: attachment.imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.15)
                    .overlay(Image(systemName: "photo"))
            }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadPhotoAttachments(from items: [PhotosPickerItem]) async {
        var attachments: [PhotoAttachment] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let normalizedData = normalizedImageData(from: data) else {
                continue
            }
            let filename = item.itemIdentifier ?? "photo-\(index + 1).jpg"
            attachments.append(PhotoAttachment(filename: filename, imageData: normalizedData))
        }
        photoAttachments = attachments
    }

    private func normalizedImageData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let resized = image.kronikuScaled(maxDimension: 1400)
        return resized.jpegData(compressionQuality: 0.62) ?? data
    }

    private func toggleVoiceRecording() async {
        guard canUseVoiceFlow else {
            voiceErrorMessage = "Enable voice transcription capture in Settings first."
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
        if let extractedPersonName = result.extractedPersonName, trimmedPersonName.isEmpty {
            personName = extractedPersonName
        }
        if let extractedInteraction = result.extractedInteraction {
            interaction = extractedInteraction
        }
        if let extractedOccurredAt = result.extractedOccurredAt {
            occurredAt = extractedOccurredAt
        }
        if trimmedNote.isEmpty {
            note = result.transcript
        }
    }

    private func resolvePersonFromContacts() async {
        guard contextController.consent.contactsResolutionEnabled else { return }

        if tier2Controller.contactsPermission == .notDetermined {
            await tier2Controller.requestContactsPermission()
        }
        guard tier2Controller.contactsPermission == .authorized else {
            return
        }
        resolvedPerson = await tier2Controller.resolvePerson(named: trimmedPersonName)
        if let resolvedPerson {
            personName = resolvedPerson.displayName
        }
    }
}

private extension UIImage {
    func kronikuScaled(maxDimension: CGFloat) -> UIImage {
        let width = size.width
        let height = size.height
        let longest = max(width, height)
        guard longest > maxDimension else { return self }

        let ratio = maxDimension / longest
        let targetSize = CGSize(width: width * ratio, height: height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
