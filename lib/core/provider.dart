import 'models.dart';

abstract class MusicProvider {
  String get id;
  bool get isConfigured;

  Future<SearchResults> search(String query);
  Future<StreamSpec> resolveStream(Track track, QualityPref pref);
}
