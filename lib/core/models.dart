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

  const StreamSpec({
    required this.uri,
    required this.contentType,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.expiresAt,
  });
}
