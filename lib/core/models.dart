enum QualityPref { highest, balanced, lowest }

class Track {
  final String providerId;
  final String id;
  final String title;
  final List<String> artists;
  final String? album;
  final Duration? duration;
  final String? artwork;
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  /// ISRC recording identifier, when the source exposes one (Spotify
  /// does). Reserved for future cross-source matching beyond title|artist.
  final String? isrc;

  const Track({
    required this.providerId,
    required this.id,
    required this.title,
    this.artists = const [],
    this.album,
    this.duration,
    this.artwork,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.isrc,
  });
}

class Album {
  final String providerId;
  final String id;
  final String title;
  final List<String> artists;
  final int? year;
  final String? artwork;
  final List<Track> tracks;

  const Album({
    required this.providerId,
    required this.id,
    required this.title,
    this.artists = const [],
    this.year,
    this.artwork,
    this.tracks = const [],
  });
}

class SearchResults {
  final List<Track> tracks;
  final List<Album> albums;
  const SearchResults({this.tracks = const [], this.albums = const []});
}

class StreamSpec {
  final Uri uri;
  final String contentType;
  final int? bitrate;
  final int? sampleRate;
  final int? bitDepth;
  final DateTime? expiresAt;

  /// Metadata that only arrives with the stream (e.g. Qobuz getFileUrl
  /// carries album art/title the favorites endpoint omits). Filled
  /// into the merged track and persisted when missing.
  final String? artwork;
  final String? album;

  const StreamSpec({
    required this.uri,
    required this.contentType,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.expiresAt,
    this.artwork,
    this.album,
  });
}
