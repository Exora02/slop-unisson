/// Upscale artwork URLs for large displays (full player).
///
/// Qobuz's static CDN serves sized variants via filename suffix
/// (_50/_100/_230/_600) — ask for the _1000 cut instead.
/// YouTube/Google thumbnails take a `=wNN-hNN` size specifier — bump it.
/// ytimg hqdefault (480x360) -> maxresdefault (up to 1280x720).
///
/// Callers must keep the original URL as an errorBuilder fallback: some
/// covers don't have the larger cut and 404.
String hqArtwork(String url) {
  var u = url.replaceAllMapped(
    RegExp(r'_(50|100|230|600)\.(jpg|jpeg|png)$', caseSensitive: false),
    (m) => '_1000.${m.group(2)}',
  );
  u = u.replaceAllMapped(RegExp(r'=w\d+(-h\d+)?'), (_) => '=w1200-h1200');
  u = u.replaceFirst('hqdefault.jpg', 'maxresdefault.jpg');
  return u;
}
