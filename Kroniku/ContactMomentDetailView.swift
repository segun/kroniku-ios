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

    private var detailMetadata: [ContextCard.MetadataEntry] {
        let metadata = event.contextCard?.metadata ?? []
        return metadata.filter { entry in
            !(entry.key == "interactionType" || entry.key == "captureMethod")
        }
    }

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
        ZStack {
            KronikuPalette.canvasGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.isReadOnlySource ? "Calendar detail" : "Edit moment")
                            .font(.title2.weight(.bold))
                            .fontDesign(.rounded)
                            .foregroundStyle(KronikuPalette.paper)
                        Text(event.isReadOnlySource ? "Read-only source metadata" : "Refine how this memory is stored")
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
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(entry.key.capitalized)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(entry.value)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                            }
                        }
                        .kronikuCard()
                    } else {
                        VStack(spacing: 12) {
                            fieldBlock(title: "When") {
                                DatePicker("Occurred at", selection: $occurredAt, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                            }

                            fieldBlock(title: "Interaction") {
                                Picker("Interaction", selection: $interaction) {
                                    ForEach(Interaction.allCases) { i in
                                        Label(i.title, systemImage: i.symbol).tag(i)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            fieldBlock(title: "Who") {
                                TextField("Person name", text: $personName)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            fieldBlock(title: "Note") {
                                TextEditor(text: $note)
                                    .frame(minHeight: 130)
                                    .padding(6)
                                    .background(KronikuPalette.sand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            if !detailMetadata.isEmpty || event.place != nil || event.weatherSnapshot != nil {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Context")
                                        .font(.headline.weight(.semibold))
                                        .fontDesign(.rounded)

                                    if let place = event.place?.name, !place.isEmpty {
                                        metadataRow(title: "Place", value: place)
                                    }

                                    if let weather = event.weatherSnapshot,
                                       let condition = weather.condition,
                                       let temperatureC = weather.temperatureC {
                                        metadataRow(title: "Weather", value: "\(condition), \(Int(temperatureC.rounded()))C")
                                    }

                                    ForEach(detailMetadata) { entry in
                                        metadataRow(title: entry.key, value: entry.value)
                                    }
                                }
                            }

                            if event.contactMoment != nil {
                                Button(role: .destructive) { deleteBoth() } label: {
                                    Label("Delete contact moment", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                                .padding(.top, 6)
                            }
                        }
                        .kronikuCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .navigationTitle("Contact moment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !event.isReadOnlySource {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .fontWeight(.semibold)
                        .disabled(personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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

    private func metadataRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.capitalized)
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
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
            let preservedMetadata = detailMetadata
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "interaction",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: cm.captureMethod)
                ] + preservedMetadata
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
            let preservedMetadata = detailMetadata
            event.contextCard = ContextCard(
                source: "contactMoment",
                category: "interaction",
                summary: note,
                metadata: [
                    .init(key: "interactionType", value: interaction.rawValue),
                    .init(key: "captureMethod", value: "typed")
                ] + preservedMetadata
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
