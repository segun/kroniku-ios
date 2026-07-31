import SwiftUI
import SwiftData

struct ContactMomentCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var note = ""
    @State private var personName = ""
    @State private var interaction = Interaction.call
    @State private var isListening = false
    @State private var occurredAt = Date()
    @State private var saveErrorMessage: String?

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
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Button { isListening.toggle() } label: {
                        Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 76))
                            .foregroundStyle(isListening ? .red : .indigo)
                            .symbolEffect(.pulse, isActive: isListening)
                    }
                    Text(isListening ? "Listening…" : "Record a moment")
                        .font(.title2.bold())
                    Text("Say what happened, then review it before saving.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 6)

                Picker("Interaction", selection: $interaction) {
                    ForEach(Interaction.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Who?").font(.headline)
                    TextField("Person name (optional)", text: $personName)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What happened?").font(.headline)
                    TextField("e.g. Called Mr. Kroenke about the contract", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                DatePicker("When", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])

                Spacer()
            }
            .padding()
            .navigationTitle("Contact moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContactMoment() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
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

    private func saveContactMoment() {
        let repo = SwiftDataMemoryRepository(modelContext: modelContext)
        do {
            try repo.addContactMoment(personName: trimmedPersonName, interactionType: interaction.rawValue, occurredAt: occurredAt, note: trimmedNote)
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
