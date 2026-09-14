import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:dart_shared_memory/dart_shared_memory.dart';
import 'package:test/test.dart';

Future<List<Map<String, Object?>>> historyWorker(
  String name,
  int seed,
) => Isolate.run(() {
  final random = Random(seed);
  final store = SharedStore.open(name: name);
  final history = <Map<String, Object?>>[];
  try {
    for (var i = 0; i < 2; i++) {
      final start = DateTime.now().microsecondsSinceEpoch;
      final snapshot = store.read(['x'])['x']!;
      history.add({
        'start': start,
        'end': DateTime.now().microsecondsSinceEpoch,
        'kind': 'read',
        'revision': snapshot.revision,
        'value': snapshot.value[0],
      });
      // Different pure calculations encourage conflicting writes, not just increments.
      final value = random.nextInt(255);
      final commitStart = DateTime.now().microsecondsSinceEpoch;
      final result = store.commit(
        checks: {'x': snapshot.revision},
        changes: {
          'x': Uint8List.fromList([value]),
        },
      );
      history.add({
        'start': commitStart,
        'end': DateTime.now().microsecondsSinceEpoch,
        'kind': 'commit',
        'expected': snapshot.revision,
        'ok': result.committed,
        'revision': result.revisions['x'],
        'value': value,
      });
    }
  } finally {
    store.close();
  }
  return history;
});

// Search legal linearizations respecting non-overlapping operation intervals.
bool consistent(
  List<Map<String, Object?>> pending,
  EntryRevision revision,
  int value,
) {
  if (pending.isEmpty) return true;
  for (var i = 0; i < pending.length; i++) {
    final event = pending[i];
    if (pending.any(
      (other) =>
          !identical(other, event) &&
          (other['end'] as int) < (event['start'] as int),
    )) {
      continue;
    }
    var nextRevision = revision;
    var nextValue = value;
    if (event['kind'] == 'read') {
      if (event['revision'] != revision || event['value'] != value) continue;
    } else {
      final matches = event['expected'] == revision;
      if (event['ok'] != matches) continue;
      if (matches) {
        nextRevision = event['revision'] as EntryRevision;
        nextValue = event['value'] as int;
      }
    }
    final remaining = [...pending]..removeAt(i);
    if (consistent(remaining, nextRevision, nextValue)) return true;
  }
  return false;
}

void main() {
  test(
    'random concurrent read/CAS histories have legal linearizations',
    () async {
      for (var round = 0; round < 20; round++) {
        final name = 'history-$round';
        final store = SharedStore.open(name: name);
        try {
          final initial = store
              .commit(checks: {'x': null}, changes: {'x': Uint8List(1)})
              .revisions['x']!;
          final histories = await Future.wait([
            historyWorker(name, round * 2),
            historyWorker(name, round * 2 + 1),
          ]);
          expect(
            consistent(histories.expand((h) => h).toList(), initial, 0),
            isTrue,
            reason: 'round $round',
          );
        } finally {
          store.close();
        }
      }
    },
  );
}
