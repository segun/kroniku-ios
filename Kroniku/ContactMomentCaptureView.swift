import SwiftUI
import SwiftData

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
                contextEnrichment: enrichment
            )
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
