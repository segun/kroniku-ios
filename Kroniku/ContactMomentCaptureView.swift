import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ContactMomentCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController

    @State private var note = ""
    @State private var personName = ""
    @State private var interaction = Interaction.call
    @State private var isListening = false
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

    private var canSave: Bool {
        !(trimmedNote.isEmpty && trimmedPersonName.isEmpty)
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
                                Button { isListening.toggle() } label: {
                                    Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                                        .font(.system(size: 48, weight: .semibold))
                                        .foregroundStyle(KronikuPalette.paper)
                                        .frame(width: 76, height: 76)
                                        .background(KronikuPalette.emberGradient, in: Circle())
                                        .symbolEffect(.pulse, isActive: isListening)
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isListening ? "Listening" : "Record a moment")
                                        .font(.title2.weight(.bold))
                                        .fontDesign(.rounded)
                                        .foregroundStyle(KronikuPalette.paper)
                                    Text("Capture first, refine second.")
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
                                        .buttonStyle(.bordered)

                                        if !photoAttachments.isEmpty {
                                            attachmentStrip
                                        }
                                    }
                                } else {
                                    Text("Enable photo attachments in Tier 1 settings to link images to this memory.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
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
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadPhotoAttachments(from: newItems)
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

        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        do {
            let enrichment = await contextController.buildEnrichment(for: occurredAt)
            try repo.addContactMoment(
                personName: trimmedPersonName,
                interactionType: interaction.rawValue,
                occurredAt: occurredAt,
                note: trimmedNote,
                contextEnrichment: enrichment,
                photoAttachments: photoAttachments
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
