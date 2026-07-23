import SwiftUI

struct PlacesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Your places will appear here", systemImage: "map", description: Text("Kroniku will learn the places that matter to you."))
                .navigationTitle("Places")
        }
    }
}

struct MemoryView: View {
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ContentUnavailableView.search(text: query)
                .navigationTitle("Memory")
                .searchable(text: $query, prompt: "Ask Kroniku anything")
        }
    }
}
