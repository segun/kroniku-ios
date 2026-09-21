import SwiftUI
import Photos
import UIKit

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
    @State private var query = ""

    var body: some View {
        KronikuHeroShell(title: "", subtitle: "Retrieve Memory") {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search memory")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)

                    TextField("What did I discuss with Alex last week?", text: $query)
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
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Search is coming in Milestone 5")
                        .font(.headline.weight(.semibold))
                        .fontDesign(.rounded)
                    Text("This tab is already styled for natural-language memory retrieval and timeline filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .kronikuCard(.semantics)
        }
    }
}
