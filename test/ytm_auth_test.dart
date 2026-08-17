import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/providers/ytm/ytm_library_client.dart';

void main() {
  test('SAPISIDHASH matches reference implementation', () {
    // Vector computed independently with Python hashlib.sha1.
    final got = sapisidHash(
        '1700000000', 'test_sapisid_value', 'https://music.youtube.com');
    expect(
        got, 'SAPISIDHASH 1700000000_03ec2c2bc483b1a755a1be799a9dde00f8482477');
  });

  test('cookie parsing finds __Secure-3PAPISID', () {
    final c = YtmLibraryClient();
    c.setCookie('SOCS=CAI; VISIT_INFO=abc; __Secure-3PAPISID=secret123; HSID=x');
    expect(c.isLoggedIn, isTrue);
    c.clearCookie();
    expect(c.isLoggedIn, isFalse);
  });

  test('no SAPISID cookie -> not logged in', () {
    final c = YtmLibraryClient();
    c.setCookie('SOCS=CAI; VISIT_INFO=abc');
    expect(c.isLoggedIn, isFalse);
  });
}
