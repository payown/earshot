import SwiftUI

/// Renders podcast artwork from a URL with a graceful placeholder. Decorative
/// by default — the adjacent title carries the accessible name — so it is
/// hidden from VoiceOver unless a caller opts back in.
///
/// Unlike `AsyncImage`, this loads through ``ArtworkCache``, whose disk-backed
/// `URLCache` means previously fetched artwork is served from disk after a cold
/// launch instead of re-downloading every session (#385). The same cache backs
/// the lock-screen artwork path in `PlayerService`.
struct PodcastArtwork: View {
    let urlString: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?
    /// The URL the currently-loaded `image` belongs to, so we don't reload on
    /// every redraw and do reload when the URL changes.
    @State private var loadedURLString: String?

    /// The device's pixel-per-point scale, used to size the decoded artwork to the
    /// actual draw size so it's downsampled rather than decoded full-resolution on
    /// the main thread during scroll. (#481)
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppColor.separator, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        // Artwork is decorative and must never compete with typing or VoiceOver
        // navigation for user-initiated executor time.
        .task(id: urlString, priority: .utility) { await load() }
    }

    private func load() async {
        // Already showing the right image (or already attempted this URL) — skip.
        guard urlString != loadedURLString else { return }

        guard let urlString, let url = URL(string: urlString) else {
            image = nil
            loadedURLString = urlString
            return
        }

        // Decode to the actual draw size in pixels so a large source isn't
        // decoded full-resolution on the main thread during scroll (#481).
        let maxPixelSize = size * displayScale
        let fetched = await ArtworkCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        // The view may have been reused for a different URL while awaiting; only
        // commit if this load is still the current one.
        guard !Task.isCancelled, self.urlString == urlString else { return }
        image = fetched
        loadedURLString = urlString
    }

    private var placeholder: some View {
        ZStack {
            AppColor.groupedBackground
            Image(systemName: "antenna.radiowaves.left.and.right")
                .imageScale(.medium)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}
