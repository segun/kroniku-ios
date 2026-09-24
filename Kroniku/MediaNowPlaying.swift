import MediaPlayer

struct MediaNowPlaying: Codable, Hashable {
    var title: String
    var artist: String?
    var albumTitle: String?
    var source: String?

    var displayText: String {
        let creator = artist ?? albumTitle
        guard let creator, !creator.isEmpty else { return title }
        return "\(title) · \(creator)"
    }
}

enum MediaNowPlayingProvider {
    static func current() -> MediaNowPlaying? {
        guard let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem,
              let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        return MediaNowPlaying(
            title: title,
            artist: item.artist?.trimmingCharacters(in: .whitespacesAndNewlines),
            albumTitle: item.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            source: item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}