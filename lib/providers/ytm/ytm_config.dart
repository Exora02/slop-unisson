// Shared YTM web client constants.
const ytmDomain = 'https://music.youtube.com';
const ytmApiBase = '$ytmDomain/youtubei/v1';
const ytmWebKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
const ytmUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0';

String ytmWebClientVersion() {
  final d = DateTime.now().toUtc();
  final ymd = '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  return '1.$ymd.01.00';
}
