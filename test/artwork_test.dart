import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/core/artwork.dart';

void main() {
  test('Qobuz CDN suffix gets upgraded to _1000', () {
    expect(
      hqArtwork('https://static.qobuz.com/images/covers/ab/cd/123_600.jpg'),
      'https://static.qobuz.com/images/covers/ab/cd/123_1000.jpg',
    );
  });

  test('Qobuz small variants also upgrade', () {
    expect(hqArtwork('https://x/covers/9/8/7_50.png'), 'https://x/covers/9/8/7_1000.png');
    expect(hqArtwork('https://x/covers/9/8/7_230.jpeg'), 'https://x/covers/9/8/7_1000.jpeg');
  });

  test('Google thumbnail size param gets bumped', () {
    expect(
      hqArtwork('https://lh3.googleusercontent.com/xyz=w60-h60'),
      'https://lh3.googleusercontent.com/xyz=w1200-h1200',
    );
  });

  test('ytimg hqdefault upgrades to maxresdefault', () {
    expect(
      hqArtwork('https://i.ytimg.com/vi/abc/hqdefault.jpg'),
      'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
    );
  });

  test('unknown URL passes through unchanged', () {
    expect(hqArtwork('https://example.com/art.jpg'),
        'https://example.com/art.jpg');
  });
}
