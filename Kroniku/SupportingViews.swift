import SwiftUI
import Photos
import UIKit
import SwiftData

struct PhotoAttachmentThumbnail: View {
    let attachment: PhotoAttachment
    let size: CGSize

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.15)
                    .overlay(Image(systemName: "photo"))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: attachment) {
            image = await loadImage()
        }
    }

    private func loadImage() async -> UIImage? {
        if let imageData = attachment.imageData {
            return UIImage(data: imageData)
        }
        guard let assetIdentifier = attachment.assetIdentifier else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let scale = await UIScreen.main.scale
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { result, _ in
                continuation.resume(returning: result)
            }
        }
    }
}

struct PlacesView: View {
    var body: some View {
        KronikuHeroShell(title: "Places with memory gravity", subtitle: "Context Atlas") {
            VStack(spacing: 14) {
                insightCard(
                    icon: "mappin.and.ellipse",
                    title: "Frequent anchors",
                    detail: "Kroniku will surface home, work, and recurring places once location consent is enabled."
                )

                insightCard(
                    icon: "clock.badge.checkmark",
                    title: "Temporal patterns",
                    detail: "Places are linked to specific moments so memory cards can recall where and when events happened."
                )

                Text("No places captured yet")
                    .font(.headline.weight(.semibold))
                    .fontDesign(.rounded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)

                Text("Enable location capture in settings and save a few moments to see your first place graph.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .kronikuCard(.context)
        }
    }

    private func insightCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(KronikuPalette.paper)
                .frame(width: 34, height: 34)
                .background(KronikuPalette.emberGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .fontDesign(.rounded)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct MemoryView: View {
    private enum SearchMode: String, CaseIterable, Identifiable {
        case keyword = "Keyword"
        case naturalLanguage = "Natural language"
        var id: String { rawValue }
    }

    private enum EventSource: String, CaseIterable, Identifiable {
        case contactMoment, calendar, trip, workout, coreLocation, coreMotion, healthKit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .contactMoment: return "Contact Moment"
            case .calendar: return "Calendar"
            case .trip: return "Trip"
            case .workout: return "Workout"
            case .coreLocation: return "Location"
            case .coreMotion: return "Motion"
            case .healthKit: return "Health"
            }
        }
    }

    private enum DetailTarget: Identifiable {
        case local(MemoryEvent)
        case remoteOnly(PullEventResponse)

        var id: String {
            switch self {
            case .local(let event): return event.id.uuidString
            case .remoteOnly(let result): return result.id
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contextController: Tier1ContextController
    @State private var searchMode: SearchMode = .keyword
    @State private var keyword = ""
    @State private var selectedSource: EventSource?
    @State private var naturalQuery = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var results: [PullEventResponse] = []
    @State private var hasSearched = false
    @State private var retrievalOptIn = false
    @State private var detailTarget: DetailTarget?

    private var canSearch: Bool {
        switch searchMode {
        case .keyword:
            return !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSource != nil
        case .naturalLanguage:
            return !naturalQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            KronikuHeroShell(title: "", subtitle: "Retrieve Memory") {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Search memory")
                            .font(.headline.weight(.semibold))
                            .fontDesign(.rounded)

                        Picker("Search mode", selection: $searchMode) {
                            ForEach(SearchMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch searchMode {
                        case .keyword:
                            keywordFields
                        case .naturalLanguage:
                            naturalLanguageField
                        }

                        Button(action: runSearch) {
                            HStack {
                                if isSearching {
                                    ProgressView()
                                }
                                Text(isSearching ? "Searching…" : "Search")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(KronikuPalette.ember)
                        .disabled(!canSearch || isSearching)
                    }

                    Divider()

                    searchResultsSection
                }
                .kronikuCard(.semantics)
            }
            .onAppear {
                retrievalOptIn = (try? AuthService.shared.getRetrievalOptIn()) ?? false
            }
            .sheet(item: $detailTarget) { target in
                switch target {
                case .local(let event):
                    NavigationStack {
                        ContactMomentDetailView(event: event)
                    }
                case .remoteOnly(let result):
                    NavigationStack {
                        RemoteSearchResultDetailView(result: result)
                    }
                }
            }
        }
    }

    private var keywordFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Keyword, e.g. \"Alex\" or \"lunch\"", text: $keyword)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KronikuPalette.sand)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .submitLabel(.search)
                .onSubmit(runSearch)

            Menu {
                Button("Any source") { selectedSource = nil }
                ForEach(EventSource.allCases) { source in
                    Button(source.title) { selectedSource = source }
                }
            } label: {
                HStack {
                    Text("Source")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(selectedSource?.title ?? "Any")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KronikuPalette.sand)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
            }

            Text("Fill in a keyword, choose a source, or both.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var naturalLanguageField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What did I discuss with Alex last week?", text: $naturalQuery)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KronikuPalette.sand)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .submitLabel(.search)
                .onSubmit(runSearch)
                .disabled(!retrievalOptIn)

            if !retrievalOptIn {
                Text("Turn on natural-language retrieval in Settings → General → Search to use this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !hasSearched {
            VStack(alignment: .leading, spacing: 6) {
                Text("Find a memory")
                    .font(.headline.weight(.semibold))
                    .fontDesign(.rounded)
                Text("Search keywords and sources across your synced timeline, or ask a natural-language question.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if results.isEmpty {
            Text("No memories matched your search")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(results, id: \.id) { result in
                    TimelineRow(event: displayEvent(for: result), schedule: contextController.consent.effectiveDayPeriodSchedule)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openDetail(for: result)
                        }
                }
            }
        }
    }

    private func openDetail(for result: PullEventResponse) {
        if let localEvent = findLocalEvent(eventId: result.eventId) {
            detailTarget = .local(localEvent)
        } else {
            detailTarget = .remoteOnly(result)
        }
    }

    private func findLocalEvent(eventId: String) -> MemoryEvent? {
        let events = (try? modelContext.fetch(FetchDescriptor<MemoryEvent>())) ?? []
        return events.first { $0.backendEventId == eventId || $0.id.uuidString == eventId }
    }

    /// Renders from the local, fully-detailed event when we have it; otherwise builds a display-only
    /// (never persisted) event from the search result so the row still looks consistent with the Timeline.
    private func displayEvent(for result: PullEventResponse) -> MemoryEvent {
        if let localEvent = findLocalEvent(eventId: result.eventId) {
            return localEvent
        }

        let event = MemoryEvent(
            occurredAt: result.occurredAt,
            source: result.source,
            title: result.title,
            detail: result.detail,
            context: result.searchText,
            symbolName: Self.defaultSymbolName(for: result.source),
            colorName: Self.defaultColorName(for: result.source),
            backendEventId: result.eventId,
            syncedToBackendAt: result.updatedAt,
            payloadHash: result.payloadHash,
            encryptedPayload: result.encryptedPayload,
            isDeleted: result.isDeleted
        )
        SwiftDataMemoryRepository.apply(contextData: result.contextData, to: event)
        return event
    }

    private static func defaultSymbolName(for source: String) -> String {
        switch source {
        case "calendar": return "calendar"
        case "trip": return "car.fill"
        case "workout": return "figure.run"
        case "coreLocation": return "mappin.and.ellipse"
        case "coreMotion": return "figure.walk"
        case "healthKit": return "heart.text.square"
        default: return "sparkles"
        }
    }

    private static func defaultColorName(for source: String) -> String {
        switch source {
        case "calendar": return "orange"
        case "trip", "workout": return "pink"
        default: return "indigo"
        }
    }

    private func runSearch() {
        isSearching = true
        errorMessage = nil

        Task {
            do {
                let events: [PullEventResponse]
                switch searchMode {
                case .naturalLanguage:
                    let trimmed = naturalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    let response = try await SearchService.shared.naturalSearch(query: trimmed)
                    events = response.results.map { $0.event }
                case .keyword:
                    let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    let response = try await SearchService.shared.keywordSearch(
                        query: trimmedKeyword.isEmpty ? nil : trimmedKeyword,
                        source: selectedSource?.rawValue
                    )
                    events = response.results
                }

                await MainActor.run {
                    results = events
                    hasSearched = true
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? HTTPError)?.errorDescription ?? error.localizedDescription
                    hasSearched = true
                    isSearching = false
                }
            }
        }
    }
}

struct RemoteSearchResultDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let result: PullEventResponse

    var body: some View {
        Form {
            Section("Memory") {
                if let title = result.title {
                    LabeledContent("Title", value: title)
                }
                if let detail = result.detail {
                    LabeledContent("Detail", value: detail)
                }
                LabeledContent("Source", value: result.source)
                LabeledContent("Occurred", value: result.occurredAt.formatted(.dateTime.weekday().month().day().hour().minute()))
            }

            Section {
                Text("This memory hasn't synced to this device yet, so only the fields that were used to find it are shown here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}
