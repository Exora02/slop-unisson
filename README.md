# Unison

One music player for everything you listen to: local files (MP3/FLAC), Qobuz (hi-res),
YouTube Music (breadth). Spotify/Tidal later. Cross-platform: Win/Mac/Linux/Android, iOS later.

Serverless by design — no Music Assistant server, providers talk to services directly.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| UI | Flutter | single codebase, snappy controls |
| Audio v1 | just_audio + audio_service | lossless decode, shared-mode output |
| Audio v2 | Rust cpal exclusive engine | true bit-perfect: WASAPI-exclusive / ALSA direct / CoreAudio hog / AAudio |
| Qobuz | MA provider logic port (Dart) | Qobuz v0.2 API, subscriber credentials |
| YTM search | dart_ytmusic_api (MusilyApp) | GPL-3.0 — reference only, reimplement if needed |
| YTM streams | pure-Dart InnerTube port (lib/providers/ytm/innertube.dart) | client ladder ANDROID_MUSIC→VR→ANDROID→TESTSUITE; audios_resolver's Linux stub is unusable, so ported its Kotlin logic to Dart for all platforms |
| Local | directory scan + metadata (mutagen-equivalent) | |
| Library | SQLite (drift) | MusicBrainz ID keyed, source priority local > qobuz > ytm |

## Provider abstraction

```dart
abstract class MusicProvider {
  String get id;          // 'local' | 'qobuz' | 'ytm' | ...
  bool get isConfigured;
  Stream<SearchResults> search(String query);
  Stream<List<Track>> getAlbum(String albumId);
  Future<StreamSpec> resolveStream(TrackRef track, QualityPref pref);
  Future<Uri?> resolveImage(ImageRef image);
}
```

StreamSpec = { url | ciphered bytes, contentType, bitrate, sampleRate, bitDepth, expiresAt }.
QualityPref = highest | balanced | lowest-data. Each provider picks its best format tier.

## Playback quality ladder (v1)

- Qobuz: FLAC up to 24/192 (subscription tier), fallback 320kbps mp3
- YTM: opus 251 (~150kbps) > m4a 140 (128kbps) — no hi-res on YT
- Local: original file, no transcode

## Source selection UX

Every album/track resolves against all configured providers → merged card.
User picks: auto (priority local > qobuz > ytm) or manual per-play source + quality.
Mixed-source queue supported.

## Milestones

- [x] M0: YTM feasibility spike (search ✅, yt-dlp stream ✅, signatureCipher wall found)
- [ ] M1: Flutter scaffold + provider interface + YTM search/play e2e (desktop)
- [ ] M2: Local files provider + merged library (SQLite, MusicBrainz matching)
- [ ] M3: Qobuz provider (auth, search, hi-res stream) — needs subscription credentials
- [ ] M4: source selector + quality preference UI, mixed-source queue
- [ ] M5: Rust cpal exclusive playback engine (desktop first)
- [ ] M6: Android build, media session, background playback
- [ ] M7: Tidal/Spotify providers if subscribed; iOS port

## References (spec material)

- music-assistant/server providers/qobuz + ytmusic (Apache-2.0)
- ytmusicapi (MIT) — YTM web-client API reference
- audios_resolver (MIT) — InnerTube stream resolution
- InnerTune/RiMusic (GPL) — Android-client API extraction reference
- qbz (MIT, Rust) — bit-perfect Qobuz desktop reference
- cpal — exclusive audio backends
