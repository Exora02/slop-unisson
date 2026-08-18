import 'models.dart';

abstract class MusicProvider {
  String get id;
  bool get isConfigured;

  /// Whether this source offers meaningfully different quality tiers
  /// (hi-res vs CD vs lossy). Single-format sources (YTM's best opus,
  /// local files) return false so the UI doesn't offer a pointless choice.
  bool get hasQualityTiers => false;

  Future<SearchResults> search(String query);
  Future<StreamSpec> resolveStream(Track track, QualityPref pref);
}
