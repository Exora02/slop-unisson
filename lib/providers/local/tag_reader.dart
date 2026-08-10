import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FileTags {
  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;
  final int? sampleRate;
  final int? bitDepth;

  const FileTags({
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.sampleRate,
    this.bitDepth,
  });
}

/// Pure-Dart audio tag reader — no native code, works on every platform.
/// Supports FLAC (Vorbis comments + STREAMINFO) and MP3 (ID3v2 + ID3v1).
class TagReader {
  static const _maxHeaderBytes = 256 * 1024; // read enough for tags, not the whole file

  /// Read tags from an audio file. Best-effort: never throws for tag errors.
  static Future<FileTags> read(String path) async {
    final file = File(path);
    if (!await file.exists()) return const FileTags();
    final ext = path.split('.').last.toLowerCase();
    try {
      switch (ext) {
        case 'flac':
          return _readFlac(file);
        case 'mp3':
          return _readMp3(file);
        default:
          return const FileTags();
      }
    } catch (_) {
      return const FileTags();
    }
  }

  // ---- FLAC ----
  static Future<FileTags> _readFlac(File file) async {
    final len = await file.length();
    final readLen = len < _maxHeaderBytes ? len : _maxHeaderBytes;
    final raf = await file.open();
    final bytes = await raf.read(readLen);
    await raf.close();
    return _parseFlac(bytes);
  }

  static FileTags _parseFlac(Uint8List b) {
    // "fLaC" magic
    if (b.length < 4 || b[0] != 0x66 || b[1] != 0x4c || b[2] != 0x61 || b[3] != 0x43) {
      return const FileTags();
    }
    int off = 4;
    String? title, artist, album;
    int? sampleRate, bitDepth, totalSamples;

    while (off + 4 <= b.length) {
      final header = b[off];
      final isLast = (header & 0x80) != 0;
      final blockType = header & 0x7f;
      final blen = (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
      off += 4;
      if (off + blen > b.length) break;

      if (blockType == 0) {
        // STREAMINFO: 18 bytes
        if (blen >= 18) {
          sampleRate = (b[off + 10] << 12) | (b[off + 11] << 4) | ((b[off + 12] >> 4) & 0x0f);
          bitDepth = ((b[off + 12] & 0x0f) << 1) | ((b[off + 13] >> 7) & 0x01);
          totalSamples = ((b[off + 13] & 0x7f) << 33) |
              (b[off + 14] << 25) |
              (b[off + 15] << 17) |
              (b[off + 16] << 9) |
              (b[off + 17] << 1) |
              ((b[off + 18 - 1] >> 7) & 0x01);
        }
      } else if (blockType == 4) {
        // VORBIS_COMMENT
        var p = off;
        int u32(int at) =>
            (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24));
        if (p + 4 > off + blen) break;
        final vendorLen = u32(p);
        p += 4 + vendorLen;
        if (p + 4 > off + blen) break;
        final count = u32(p);
        p += 4;
        for (var i = 0; i < count && p + 4 <= off + blen; i++) {
          final clen = u32(p);
          p += 4;
          if (p + clen > off + blen) break;
          final comment = utf8Decode(b.sublist(p, p + clen));
          p += clen;
          final eq = comment.indexOf('=');
          if (eq > 0) {
            final key = comment.substring(0, eq).toUpperCase();
            final value = comment.substring(eq + 1);
            switch (key) {
              case 'TITLE':
                title ??= value;
                break;
              case 'ARTIST':
                artist ??= value;
                break;
              case 'ALBUM':
                album ??= value;
                break;
            }
          }
        }
      }

      off += blen;
      if (isLast) break;
    }

    Duration? dur;
    if (sampleRate != null && sampleRate > 0 && totalSamples != null && totalSamples > 0) {
      dur = Duration(milliseconds: (totalSamples * 1000 / sampleRate).round());
    }
    return FileTags(
      title: title,
      artist: artist,
      album: album,
      duration: dur,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
    );
  }

  // ---- MP3 ----
  static Future<FileTags> _readMp3(File file) async {
    final len = await file.length();
    final readLen = len < _maxHeaderBytes ? len : _maxHeaderBytes;
    final raf = await file.open();
    final bytes = await raf.read(readLen);
    await raf.close();
    return _parseMp3(bytes, len);
  }

  static FileTags _parseMp3(Uint8List b, int fileLen) {
    String? title, artist, album;
    // ID3v2 at start: "ID3"
    if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
      final size = ((b[6] & 0x7f) << 21) | ((b[7] & 0x7f) << 14) | ((b[8] & 0x7f) << 7) | (b[9] & 0x7f);
      final end = size + 10;
      if (end <= b.length) {
        var p = 10;
        final tagEnd = 10 + size;
        while (p + 10 <= tagEnd) {
          final frameId = String.fromCharCodes(b.sublist(p, p + 4));
          final fsize = ((b[p + 4] & 0x7f) << 21) | ((b[p + 5] & 0x7f) << 14) |
              ((b[p + 6] & 0x7f) << 7) | (b[p + 7] & 0x7f);
          // flags at b[p+8] (unsets); data follows at p+10
          final dataStart = p + 10;
          if (frameId == 'TIT2' || frameId == 'TPE1' || frameId == 'TALB') {
            if (dataStart + 1 <= tagEnd && dataStart + fsize <= tagEnd) {
              // skip encoding byte
              var val = '';
              try {
                val = utf8Decode(b.sublist(dataStart + 1, dataStart + fsize)).trim();
              } catch (_) {
                val = '';
              }
              if (frameId == 'TIT2' && title == null) title = val;
              if (frameId == 'TPE1' && artist == null) artist = val;
              if (frameId == 'TALB' && album == null) album = val;
            }
          }
          if (fsize <= 0) break;
          p = dataStart + fsize;
        }
      }
    }
    // ID3v1 fallback at end
    if (b.length >= 128) {
      final tail = b.sublist(b.length - 128);
      if (tail[0] == 0x54 && tail[1] == 0x41 && tail[2] == 0x47) {
        title ??= latin1Decode(tail.sublist(3, 33)).trim();
        artist ??= latin1Decode(tail.sublist(33, 63)).trim();
        album ??= latin1Decode(tail.sublist(63, 93)).trim();
      }
    }
    // estimate duration from CBR bitrate if we can find a frame header
    Duration? dur;
    final br = _mp3Bitrate(b);
    if (br != null && br > 0) {
      // audio payload ≈ fileLen minus up to 1KB of tag/header
      final payload = fileLen > 1024 ? fileLen - 1024 : fileLen;
      dur = Duration(milliseconds: (payload * 8000 / br).round());
    }
    return FileTags(title: title, artist: artist, album: album, duration: dur);
  }

  /// crude MP3 frame bitrate detection (kbps -> bps)
  static int? _mp3Bitrate(Uint8List b) {
    const table = [
      [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
      [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
      [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    ];
    // scan for first 0xFFEx sync frame
    for (var i = 0; i + 4 < b.length && i < 64 * 1024; i++) {
      if (b[i] == 0xff && (b[i + 1] & 0xe0) == 0xe0) {
        final ver = (b[i + 1] >> 3) & 0x03;
        final layer = (b[i + 1] >> 1) & 0x03;
        final brIdx = (b[i + 2] >> 4) & 0x0f;
        if (ver == 1 && layer == 1) return table[0][brIdx] * 1000;
        if (layer == 1 || layer == 2) return table[1][brIdx] * 1000;
        return table[2][brIdx] * 1000;
      }
    }
    return null;
  }

  static String utf8Decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // fall back to latin1
      return latin1Decode(bytes);
    }
  }

  static String latin1Decode(List<int> bytes) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      return '';
    }
  }
}