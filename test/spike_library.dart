import 'package:unisson/core/library_service.dart';
import 'package:unisson/core/models.dart';
import 'package:unisson/providers/ytm/ytm_provider.dart';

Future<void> main() async {
  final ytm = YtmProvider();
  final lib = LibraryService([ytm]);

  print('== MERGED SEARCH (YTM only) ==');
  final results = await lib.searchAll('daft punk veridis quo');
  print('got ${results.length} merged tracks');
  for (final t in results.take(5)) {
    print('  [${t.bestSourceId}] ${t.title} | ${t.artists.join(",")} | ${t.album} | srcs=${t.sources.keys.join(",")}');
  }
  if (results.isEmpty) {
    print('NO RESULTS');
  } else {
    final first = results.first;
    print('\n== AUTO RESOLVE (best source) ==');
    final r = await lib.resolveAuto(first, QualityPref.highest);
    print('resolved from ${r.sourceId}: ${r.title}');
    print('  host: ${r.stream.uri.host}');
    print('  content-type: ${r.stream.contentType}');
    print('  VERDICT: PASS');
  }
  ytm.dispose();
}