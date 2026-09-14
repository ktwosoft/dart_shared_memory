import 'dart:typed_data';

import 'package:dart_shared_memory/dart_shared_memory.dart';

/// Creates, reads, conditionally updates, and deletes a binary value.
void main() {
  final store = SharedStore.open(name: 'quick-start');
  try {
    final created = store.commit(
      checks: {'counter': null},
      changes: {'counter': Uint8List(8)},
    );
    if (!created.committed) throw StateError('Counter already exists');

    final snapshot = store.read(['counter'])['counter']!;
    final bytes = snapshot.value;
    ByteData.sublistView(bytes).setInt64(0, 42);
    final updated = store.commit(
      checks: {'counter': snapshot.revision},
      changes: {'counter': bytes},
    );
    if (!updated.committed) throw StateError('Counter changed concurrently');
    print(
      'Counter: ${ByteData.sublistView(store.read(['counter'])['counter']!.value).getInt64(0)}',
    );

    final deleted = store.commit(
      checks: {'counter': updated.revisions['counter']!},
      changes: {'counter': null},
    );
    print('Deleted: ${deleted.committed}');
  } finally {
    store.close();
  }
}
