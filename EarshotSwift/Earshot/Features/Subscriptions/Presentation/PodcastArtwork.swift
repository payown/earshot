import SwiftUI

/// Renders podcast artwork from a URL with a graceful placeholder. Decorative
/// by default — the adjacent title carries the accessible name — so it is
/// hidden from VoiceOver unless a caller opts back in.
struct PodcastArtwork: View {
    let urlString: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
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
