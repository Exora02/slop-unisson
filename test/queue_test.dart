import 'package:flutter_test/flutter_test.dart';
import 'package:unisson/core/library_service.dart';
import 'package:unisson/core/models.dart';
import 'package:unisson/core/queue.dart';

QueueEntry entry(String title) {
  final t = Track(
    providerId: 'ytm',
    id: 'id_$title',
    title: title,
    artists: const ['Artist'],
  );
  return QueueEntry(track: MergedTrack(
    universalKey: '$title|artist',
    title: title,
    artists: const ['Artist'],
    sources: {'ytm': t},
  ));
}

void main() {
  test('replaceAll + advance + exhaustion without repeat', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b'), entry('c')]);
    expect(q.length, 3);
    expect(q.current?.track.title, 'a');
    expect(q.advance(), isTrue);
    expect(q.current?.track.title, 'b');
    expect(q.advance(), isTrue);
    expect(q.current?.track.title, 'c');
    expect(q.advance(), isFalse); // exhausted
    expect(q.current?.track.title, 'c');
  });

  test('repeat all wraps around', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b')]);
    q.repeatMode = RepeatMode.all;
    q.advance(); // b
    expect(q.advance(), isTrue); // wraps to a
    expect(q.current?.track.title, 'a');
  });

  test('repeat one stays on current', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b')]);
    q.repeatMode = RepeatMode.one;
    expect(q.nextIndex(), 0);
    q.advance();
    expect(q.current?.track.title, 'a');
    // explicit navigation still moves
    expect(q.nextIndex(peek: true), 1);
  });

  test('goBack and wrap', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b'), entry('c')]);
    q.advance(); // b
    expect(q.goBack(), isTrue);
    expect(q.current?.track.title, 'a');
    expect(q.goBack(), isFalse); // no repeat
    q.repeatMode = RepeatMode.all;
    expect(q.goBack(), isTrue);
    expect(q.current?.track.title, 'c');
  });

  test('insertNext places after current', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b')]);
    q.insertNext(entry('x'));
    expect(q.entries.map((e) => e.track.title).toList(), ['a', 'x', 'b']);
    q.advance();
    expect(q.current?.track.title, 'x');
  });

  test('add appends; empty queue starts at first add', () {
    final q = UnissonQueue();
    q.add(entry('a'));
    expect(q.current?.track.title, 'a');
    q.add(entry('b'));
    expect(q.entries.length, 2);
    expect(q.current?.track.title, 'a');
  });

  test('removeAt adjusts index and shuffle order', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b'), entry('c'), entry('d')]);
    q.advance(); // at b (index 1)
    expect(q.removeAt(0), isTrue); // remove before current
    expect(q.current?.track.title, 'b'); // b slid to index 0
    expect(q.removeAt(0), isTrue); // remove current -> c takes its slot
    expect(q.current?.track.title, 'c');
  });

  test('removeAt current when shuffled keeps playing correctly', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b'), entry('c')]);
    q.toggleShuffle();
    expect(q.playOrder.length, 3);
    expect(q.playOrder.first, 0); // current stays first
    expect(q.removeAt(0), isTrue);
    expect(q.playOrder, isNot(contains(2))); // no stale index 2
    expect(q.current?.track.title, 'b');
  });

  test('move reorders and tracks current', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a'), entry('b'), entry('c')]);
    q.advance(); // b at 1
    q.move(1, 0); // b to front
    expect(q.entries.map((e) => e.track.title).toList(), ['b', 'a', 'c']);
    expect(q.current?.track.title, 'b');
    expect(q.currentIndex, 0);
  });

  test('shuffle covers all entries exactly once, current first', () {
    final q = UnissonQueue();
    q.replaceAll(List.generate(8, (i) => entry('t$i')));
    q.advance(); // index 1
    q.toggleShuffle();
    final order = q.playOrder;
    expect(order.toSet().length, 8); // all unique
    expect(order.first, 1); // current first
    q.toggleShuffle(); // off
    expect(q.playOrder, [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('clear empties everything', () {
    final q = UnissonQueue();
    q.replaceAll([entry('a')]);
    q.clear();
    expect(q.isEmpty, isTrue);
    expect(q.hasCurrent, isFalse);
    expect(q.advance(), isFalse);
  });
}
