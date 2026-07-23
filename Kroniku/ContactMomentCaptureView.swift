import SwiftUI

struct ContactMomentCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var interaction = Interaction.call
    @State private var isListening = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
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
                .padding(.top, 18)

                Picker("Interaction", selection: $interaction) {
                    ForEach(Interaction.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What happened?").font(.headline)
                    TextField("e.g. Called Mr. Kroenke about the contract", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Contact moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private enum Interaction: String, CaseIterable, Identifiable {
    case call, text, meeting
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String { switch self { case .call: "phone.fill"; case .text: "message.fill"; case .meeting: "person.2.fill" } }
}
