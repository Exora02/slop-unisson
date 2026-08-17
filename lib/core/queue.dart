import 'dart:math';

import 'library_service.dart';

enum RepeatMode { none, all, one }

/// A single playable item in the queue.
class QueueEntry {
  final MergedTrack track;

  /// providerId to play from (null = auto best source at resolve time)
  String? sourceId;

  QueueEntry({required this.track, this.sourceId});

  String get key => '${track.universalKey}|${sourceId ?? 'auto'}';
}

/// Playback queue with repeat + shuffle semantics.
///
/// Pure Dart, no Flutter deps — unit-testable. The audio handler owns one of
/// these and mirrors state changes into audio_service's queue.
class UnissonQueue {
  final List<QueueEntry> entries = [];
  int _index = -1;

  /// Position of each entry within the shuffled order when shuffle is on.
  List<int>? _shuffleOrder;

  RepeatMode repeatMode = RepeatMode.none;
  bool shuffled = false;

  int get length => entries.length;
  bool get isEmpty => entries.isEmpty;
  bool get hasCurrent => _index >= 0 && _index < entries.length;

  QueueEntry? get current => hasCurrent ? entries[_index] : null;
  int get currentIndex => _index;

  /// Order of entry indices in which they will play, honoring shuffle.
  List<int> get playOrder =>
      shuffled && _shuffleOrder != null
          ? List<int>.unmodifiable(_shuffleOrder!)
          : List<int>.generate(entries.length, (i) => i);

  /// Replace the queue and start at [startIndex].
  void replaceAll(List<QueueEntry> newEntries, {int startIndex = 0}) {
    entries
      ..clear()
      ..addAll(newEntries);
    _index = entries.isEmpty ? -1 : startIndex.clamp(0, entries.length - 1);
    _reshuffleIfNeeded();
  }

  /// Add to the end of the queue.
  void add(QueueEntry e) {
    entries.add(e);
    if (_index == -1) _index = 0;
    if (shuffled) _shuffleOrder!.add(entries.length - 1);
  }

  /// Insert right after the current track (play next).
  void insertNext(QueueEntry e) {
    if (entries.isEmpty || _index < 0) {
      add(e);
      return;
    }
    entries.insert(_index + 1, e);
    if (shuffled) {
      final pos = _shuffleOrder!.indexOf(_index);
      _shuffleOrder!.insert(pos + 1, entries.length - 1);
      // every original index after the insert point shifted by one
      for (var i = 0; i < _shuffleOrder!.length; i++) {
        if (_shuffleOrder![i] > _index && _shuffleOrder![i] != entries.length - 1) {
          _shuffleOrder![i] += 1;
        }
      }
    }
  }

  bool removeAt(int index) {
    if (index < 0 || index >= entries.length) return false;
    entries.removeAt(index);
    if (entries.isEmpty) {
      _index = -1;
      _shuffleOrder = null;
      return true;
    }
    if (index < _index) {
      _index -= 1;
    } else if (index == _index) {
      _index = _index.clamp(0, entries.length - 1);
    }
    if (shuffled) {
      _shuffleOrder!.remove(index);
      for (var i = 0; i < _shuffleOrder!.length; i++) {
        if (_shuffleOrder![i] > index) _shuffleOrder![i] -= 1;
      }
    }
    return true;
  }

  void move(int from, int to) {
    if (from < 0 || from >= entries.length) return;
    if (to < 0 || to >= entries.length) return;
    if (from == to) return;
    final e = entries.removeAt(from);
    entries.insert(to, e);
    // current pointer follows the moved/current track
    if (_index == from) {
      _index = to;
    } else if (from < _index && to >= _index) {
      _index -= 1;
    } else if (from > _index && to <= _index) {
      _index += 1;
    }
    if (shuffled) _shuffleOrder = _buildShuffledOrder();
  }

  void toggleShuffle() {
    shuffled = !shuffled;
    if (shuffled) {
      _buildShuffledOrder();
    } else {
      _shuffleOrder = null;
    }
  }

  /// Index of the entry that should play next, or null when the queue ends
  /// (honoring repeat modes).
  int? nextIndex({bool peek = false}) {
    if (entries.isEmpty) return null;
    if (repeatMode == RepeatMode.one && !peek) return _index;
    final order = playOrder;
    final pos = order.indexOf(_index);
    if (pos < order.length - 1) return order[pos + 1];
    return repeatMode == RepeatMode.all ? order.first : null;
  }

  int? previousIndex() {
    if (entries.isEmpty) return null;
    final order = playOrder;
    final pos = order.indexOf(_index);
    if (pos > 0) return order[pos - 1];
    return repeatMode == RepeatMode.all ? order.last : null;
  }

  /// Advance to the next entry; returns false when the queue is exhausted.
  bool advance() {
    final n = nextIndex();
    if (n == null) return false;
    _index = n;
    return true;
  }

  bool goBack() {
    final p = previousIndex();
    if (p == null) return false;
    _index = p;
    return true;
  }

  void clear() {
    entries.clear();
    _index = -1;
    _shuffleOrder = null;
  }

  void _reshuffleIfNeeded() {
    if (shuffled && entries.isNotEmpty) _shuffleOrder = _buildShuffledOrder();
  }

  List<int> _buildShuffledOrder() {
    final order = List<int>.generate(entries.length, (i) => i);
    // Fisher-Yates
    final rng = _rng;
    for (var i = order.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = order[i];
      order[i] = order[j];
      order[j] = tmp;
    }
    // keep the current track first so toggling shuffle doesn't skip ahead
    final cur = order.indexOf(_index);
    if (cur > 0) {
      final tmp = order[0];
      order[0] = order[cur];
      order[cur] = tmp;
    }
    _shuffleOrder = order;
    return order;
  }

  static final _rng = Random();
}
