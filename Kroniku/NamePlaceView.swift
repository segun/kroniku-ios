import SwiftUI
import MapKit

extension GeoCoordinate: Identifiable {
    var id: String { "\(latitude),\(longitude)" }
}

/// Presented when the user taps a "name this place" notification, or opens it from the pending-places list.
struct NamePlaceView: View {
    let coordinate: GeoCoordinate

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition

    init(coordinate: GeoCoordinate) {
        self.coordinate = coordinate
        _cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Map(position: $cameraPosition) {
                    Marker("New place", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("What's this place called?")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)
                    Text("Kroniku will use this name whenever it recognizes this location again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("e.g. Mom's house", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Name this place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await NamedPlacesStore.shared.name(latitude: coordinate.latitude, longitude: coordinate.longitude, as: name)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = "Couldn't save this place. Try again."
            }
        }
    }
}
