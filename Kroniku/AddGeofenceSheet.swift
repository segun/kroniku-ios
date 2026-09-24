import SwiftUI
import MapKit
import CoreLocation

struct AddGeofenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var contextController: Tier1ContextController
    @ObservedObject private var geofenceStore = GeofenceStore.shared

    @State private var name: String = ""
    @State private var radiusMeters: Double = 150
    @State private var coordinate: GeoCoordinate?
    @State private var addressText: String = ""
    @State private var isResolvingAddress = false
    @State private var isCapturingLocation = false
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @FocusState private var isAddressFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Place name", text: $name)
                    HStack {
                        ForEach(GeofenceStore.presetNames, id: \.self) { preset in
                            Button(preset) { name = preset }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Location") {
                    Button {
                        isAddressFieldFocused = false
                        Task {
                            isCapturingLocation = true
                            coordinate = await contextController.captureCurrentCoordinate()
                            isCapturingLocation = false
                            if coordinate == nil {
                                showToast("Can't find address")
                            }
                        }
                    } label: {
                        Label(isCapturingLocation ? "Locating…" : "Use current location", systemImage: "location.fill")
                    }
                    .disabled(isCapturingLocation)

                    HStack {
                        TextField("Enter address", text: $addressText)
                            .focused($isAddressFieldFocused)
                            .submitLabel(.search)
                            .onSubmit { lookUpAddress() }
                        Button("Look up") { lookUpAddress() }
                            .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty || isResolvingAddress)
                    }

                    GeofenceMapPickerView(coordinate: $coordinate)
                        .listRowInsets(EdgeInsets())

                    if let coordinate {
                        Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Radius") {
                    Slider(value: $radiusMeters, in: 50...500, step: 10)
                    Text("\(Int(radiusMeters)) m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let coordinate else { return }
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { return }
                        geofenceStore.add(NamedGeofence(
                            name: trimmedName,
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude,
                            radiusMeters: radiusMeters
                        ))
                        contextController.refreshGeofenceMonitoringIfNeeded()
                        dismiss()
                    }
                    .disabled(coordinate == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay(alignment: .top) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.red, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toastMessage)
        }
    }

    private func lookUpAddress() {
        isAddressFieldFocused = false
        Task {
            isResolvingAddress = true
            coordinate = await Self.geocode(addressText)
            isResolvingAddress = false
            if coordinate == nil {
                showToast("Can't find address")
            }
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 2.5) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    private static func geocode(_ address: String) async -> GeoCoordinate? {
        await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, _ in
                guard let coordinate = placemarks?.first?.location?.coordinate else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
            }
        }
    }
}

private struct GeofenceMapPickerView: View {
    @Binding var coordinate: GeoCoordinate?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var suppressNextAutoZoom = false

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let coordinate {
                    Marker("Selected", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                }
            }
            .onTapGesture { point in
                guard let tapped = proxy.convert(point, from: .local) else { return }
                suppressNextAutoZoom = true
                coordinate = GeoCoordinate(latitude: tapped.latitude, longitude: tapped.longitude)
            }
        }
        .onChange(of: coordinate) { _, newValue in
            guard let newValue else { return }
            guard !suppressNextAutoZoom else {
                suppressNextAutoZoom = false
                return
            }
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: newValue.latitude, longitude: newValue.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

