import SwiftUI
import SwiftData

struct ContactMomentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let event: MemoryEvent

    @State private var personName: String = ""
    @State private var note: String = ""
    @State private var interaction: Interaction = .call
    @State private var occurredAt: Date = Date()

    init(event: MemoryEvent) {
        self.event = event
        // initialize states from linked contact moment if available
        if let cm = event.contactMoment {
            _personName = State(initialValue: cm.personName ?? "")
            _note = State(initialValue: cm.note)
            _interaction = State(initialValue: Interaction(rawValue: cm.interactionType) ?? .call)
            _occurredAt = State(initialValue: cm.occurredAt)
        } else {
            // fallback to MemoryEvent fields
            _personName = State(initialValue: event.detail ?? "")
            _note = State(initialValue: event.title ?? "")
            _occurredAt = State(initialValue: event.occurredAt ?? Date())
        }
    }

    var body: some View {
        Form {
            Section(header: Text("When")) {
                DatePicker("Occurred at", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
            }

            Section(header: Text("Interaction")) {
                Picker("Interaction", selection: $interaction) {
                    ForEach(Interaction.allCases) { i in
                        Label(i.title, systemImage: i.symbol).tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Who")) {
                TextField("Person name", text: $personName)
            }

            Section(header: Text("Note")) {
                TextEditor(text: $note)
                    .frame(minHeight: 120)
            }

            if event.contactMoment != nil {
                Section {
                    Button(role: .destructive) { deleteBoth() } label: {
                        Text("Delete contact moment")
                    }
                }
            }
        }
        .navigationTitle("Contact moment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveChanges() }
                    .fontWeight(.semibold)
                    .disabled(personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func saveChanges() {
        if let cm = event.contactMoment {
            cm.personName = personName.isEmpty ? nil : personName
            cm.note = note
            cm.interactionType = interaction.rawValue
            cm.occurredAt = occurredAt
            cm.updatedAt = Date()

            // keep MemoryEvent in sync
            event.occurredAt = occurredAt
            event.title = note
            event.detail = personName
            event.context = interaction.title
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "interaction",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: cm.captureMethod)
                ]
            )
            event.updatedAt = Date()

            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .memoryRepositoryChanged, object: nil)
            } catch {
                print("Failed to save updates: \(error)")
            }
        } else {
            // create new contact moment and link it
            let cm = ContactMoment(personName: personName.isEmpty ? nil : personName, interactionType: interaction.rawValue, occurredAt: occurredAt, note: note, captureMethod: "typed")
            cm.memoryEvent = event
            event.contactMoment = cm

            // update event fields
            event.occurredAt = occurredAt
            event.title = note
            event.detail = personName
            event.context = interaction.title
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "interaction",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: "typed")
                ]
            )

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
}
