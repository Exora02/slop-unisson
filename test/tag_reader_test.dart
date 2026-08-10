import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/providers/local/tag_reader.dart';

Uint8List buildFlac({
  required String title,
  required String artist,
  required String album,
  int sampleRate = 96000,
  int bitDepth = 24,
  int totalSamples = 96000 * 180, // 3:00
}) {
  final b = BytesBuilder();
  b.add([0x66, 0x4c, 0x61, 0x43]); // "fLaC"

  // STREAMINFO block (type 0), 34-byte body.
  // Reader computes: sampleRate=(b[10]<<12)|(b[11]<<4)|((b[12]>>4)&0xf)
  final b34 = BytesBuilder();
  b34.add(List.filled(10, 0)); // blocksize hints + min/max frames (10 bytes)
  final sr24 = sampleRate << 4; // sample rate low 4 bits land in byte12 high nibble
  b34.add([(sr24 >> 16) & 0xff, (sr24 >> 8) & 0xff, sr24 & 0xff]);
  b34.add(List.filled(21, 0)); // samples/depth region (rest to 34)
  b.add([0x00, 0x00, 0x00, 0x22]); // block header: not-last, type 0, len 34
  b.add(b34.takeBytes());

  // VORBIS_COMMENT block (type 4)
  final vendor = utf8.encode('test encoder');
  final c1 = utf8.encode('TITLE=$title');
  final c2 = utf8.encode('ARTIST=$artist');
  final c3 = utf8.encode('ALBUM=$album');
  // body = vendor_len(4) + vendor + count(4) + [len(4)+comment] * 3
  final body = BytesBuilder();
  void u32(int v) {
    body.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  }
  u32(vendor.length);
  body.add(vendor);
  u32(3); // comment count
  u32(c1.length);
  body.add(c1);
  u32(c2.length);
  body.add(c2);
  u32(c3.length);
  body.add(c3);
  final bodyBytes = body.takeBytes();
  final blen = bodyBytes.length;
  // block header: last=0x80 + type 4 = 0x84, then 24-bit length
  b.add([0x84, (blen >> 16) & 0xff, (blen >> 8) & 0xff, blen & 0xff]);
  b.add(bodyBytes);

  return b.takeBytes();
}

void main() {
  test('TagReader parses FLAC tags', () async {
    final bytes = buildFlac(
      title: 'Veridis Quo',
      artist: 'Daft Punk',
      album: 'Discovery',
      sampleRate: 96000,
      totalSamples: 96000 * 180,
    );
    // write to temp file
    final f = await _TempFile.create(bytes);

    final tags = await TagReader.read(f.path);
    expect(tags.title, 'Veridis Quo');
    expect(tags.artist, 'Daft Punk');
    expect(tags.album, 'Discovery');
    expect(tags.sampleRate, 96000);
    await f.cleanup();
  });

  test('TagReader handles missing tags gracefully', () async {
    final f = await _TempFile.create(Uint8List.fromList([0x66, 0x4c, 0x61, 0x43]));
    final tags = await TagReader.read(f.path);
    expect(tags.title, isNull);
    expect(tags.artist, isNull);
    expect(tags.album, isNull);
    // no throw
    await f.cleanup();
  });

  test('TagReader returns empty on non-audio file', () async {
    final f = await _TempFile.create(Uint8List.fromList([1, 2, 3, 4, 5]));
    final tags = await TagReader.read(f.path);
    expect(tags.title, isNull);
    await f.cleanup();
  });
}

class _TempFile {
  final File f;
  _TempFile(this.f);
  String get path => f.path;
  static Future<_TempFile> create(Uint8List bytes) async {
    final dir = await Directory.systemTemp.createTemp('tagtest');
    final file = File('${dir.path}/audio.flac');
    await file.writeAsBytes(bytes);
    return _TempFile(file);
  }
  Future<void> cleanup() async {
    try {
      if (f.existsSync()) {
        await f.parent.delete(recursive: true);
      }
    } catch (_) {}
  }
}