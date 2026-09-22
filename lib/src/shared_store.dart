import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'native_bindings.dart' as native;
import 'shared_store_types.dart';
import 'shared_store_exception.dart';

/// A synchronous handle to binary state shared within one native process.
///
/// Open a separate handle in each isolate using the same name and limits. A
/// handle cannot be sent between isolates. Keep an anchor handle open across
/// worker restarts: closing the last handle destroys all data in that store.
///
/// Reads return copies. Commits validate revisions and publish an entire batch
/// atomically. Calls may block the current isolate on locks, allocation or byte
/// copies; no background worker, retry policy or persistence is provided.
final class SharedStore implements Finalizable {
  SharedStore._(this.name, this.limits, this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }
  static final _finalizer = NativeFinalizer(
    Native.addressOf(native.closeStore),
  );

  /// Case-sensitive name identifying this store in the loaded native library.
  final String name;

  /// Limits agreed by all handles attached to this store.
  final StoreLimits limits;
  Pointer<Void> _handle;

  /// Creates a named store or attaches to its existing native context.
  ///
  /// [name] must be nonempty valid Unicode without NUL, encoded in at most
  /// 4,096 UTF-8 bytes. Names are not normalized or interpreted as paths.
  /// Existing contexts require [limits] to match exactly.
  ///
  /// Throws [ArgumentError] for an invalid name and [SharedStoreException] for
  /// invalid native limits, mismatched configuration, allocation or ABI errors.
  /// Always release the returned handle with [close], usually in `finally`.
  static SharedStore open({
    required String name,
    StoreLimits limits = const StoreLimits(),
  }) {
    if (native.abiVersion() != 1) {
      throw const SharedStoreException(SharedStoreError.abiMismatch);
    }
    final encoded = _encodeKey(name, 4096);
    return using((arena) {
      final config = arena<native.NativeLimits>();
      config.ref
        ..maxBytes = limits.maxBytes
        ..maxEntries = limits.maxEntries
        ..maxValue = limits.maxValueBytes
        ..maxKeys = limits.maxKeysPerOperation
        ..maxKey = limits.maxKeyBytes
        ..maxOperation = limits.maxOperationBytes;
      final output = arena<Pointer<Void>>();
      _check(
        native.openStore(_copy(arena, encoded), encoded.length, config, output),
      );
      try {
        return SharedStore._(name, limits, output.value);
      } catch (_) {
        native.closeStore(output.value);
        rethrow;
      }
    });
  }

  /// Captures one atomic snapshot of [keys], preserving their iteration order.
  ///
  /// Every requested key appears in the returned map; missing entries map to
  /// null. Present values are independent byte copies, even for empty values.
  /// Separate calls do not form a joint snapshot. An empty iterable returns an
  /// empty map, provided this handle is open.
  ///
  /// Throws [ArgumentError] for duplicate, invalid or oversized input keys or
  /// batches; [StateError] after [close]; and [SharedStoreException] for native
  /// resource failures. A failed read does not change stored values.
  Map<String, EntrySnapshot?> read(Iterable<String> keys) {
    _ensureOpen();
    final batch = <String>[];
    final seen = <String>{};
    for (final key in keys) {
      if (batch.length >= limits.maxKeysPerOperation || !seen.add(key)) {
        throw ArgumentError('Duplicate key or too many keys');
      }
      batch.add(key);
    }
    if (batch.isEmpty) return {};
    return _call(batch, null, null, (result) {
      final snapshots = <String, EntrySnapshot?>{};
      for (var i = 0; i < batch.length; i++) {
        final entry = result.values[i];
        snapshots[batch[i]] = entry.revision == 0
            ? null
            : EntrySnapshot(
                value: entry.size == 0
                    ? Uint8List(0)
                    : Uint8List.fromList(entry.value.asTypedList(entry.size)),
                revision: EntryRevision(entry.context, entry.revision),
              );
      }
      return snapshots;
    });
  }

  /// Copies live keys matching the literal [prefix] in bytewise sorted order.
  ///
  /// An empty prefix matches all keys. The result is immutable and bounded by
  /// [StoreLimits.maxKeysPerOperation] and [StoreLimits.maxOperationBytes].
  /// Concurrent changes after this call may differ from a later [read].
  /// Resource failures return no partial list.
  List<String> keys({String prefix = ''}) {
    _ensureOpen();
    final encoded = prefix.isEmpty
        ? Uint8List(0)
        : _encodeKey(prefix, limits.maxKeyBytes);
    return using((arena) {
      final output = arena<Pointer<native.NativeKeysResult>>();
      output.value = nullptr;
      final code = native.keysStore(
        _handle,
        _copy(arena, encoded),
        encoded.length,
        output,
      );
      try {
        _check(code);
        final result = output.value.ref;
        return List<String>.unmodifiable([
          for (var i = 0; i < result.count; i++)
            utf8.decode(result.keys[i].key.asTypedList(result.keys[i].size)),
        ]);
      } finally {
        if (output.value != nullptr) native.freeKeysResult(output.value);
      }
    });
  }

  /// Applies all [changes] atomically only if every entry in [checks] matches.
  ///
  /// A null check requires absence at commit time. A revision check requires
  /// that exact live revision. Bytes in [changes] create or replace a value;
  /// null deletes it. Every change needs a check, and deletion requires a
  /// non-null revision. Additional read-only checks are allowed. Empty byte
  /// values are valid; an empty changes map is not.
  ///
  /// A conflict returns [CommitResult.committed] false without applying changes.
  /// Re-read and recompute to retry. Input bytes are copied during the call.
  /// Expected absence does not prove a key never existed since an earlier read.
  ///
  /// Throws [ArgumentError] for invalid input or input-size violations,
  /// [StateError] after [close], and [SharedStoreException] for native failures.
  /// Staging may exhaust capacity before a conflict is detected. Native failure
  /// before publication applies nothing; failure to deliver an already successful
  /// result to Dart can leave committed changes. Re-read after an uncertain result.
  CommitResult commit({
    required Map<String, EntryRevision?> checks,
    required Map<String, Uint8List?> changes,
  }) {
    _ensureOpen();
    if (changes.isEmpty || checks.length > limits.maxKeysPerOperation) {
      throw ArgumentError('Empty changes or too many checks');
    }
    for (final key in changes.keys) {
      if (!checks.containsKey(key) ||
          changes[key] == null && checks[key] == null) {
        throw ArgumentError('Every change needs a valid precondition');
      }
    }
    return _call(
      checks.keys.toList(),
      checks,
      changes,
      (result) {
        final revisions = <String, EntryRevision?>{};
        var i = 0;
        for (final key in checks.keys) {
          final entry = result.values[i++];
          if (changes.containsKey(key)) {
            revisions[key] = entry.revision == 0
                ? null
                : EntryRevision(entry.context, entry.revision);
          }
        }
        return CommitResult(committed: true, revisions: revisions);
      },
      onConflict: () => CommitResult(committed: false, revisions: {}),
    );
  }

  T _call<T>(
    List<String> keys,
    Map<String, EntryRevision?>? checks,
    Map<String, Uint8List?>? changes,
    T Function(native.NativeResult) decode, {
    T Function()? onConflict,
  }) {
    return using((arena) {
      final inputs = arena<native.NativeInput>(keys.length);
      var total = 0;
      for (var i = 0; i < keys.length; i++) {
        final key = keys[i];
        final encoded = _encodeKey(key, limits.maxKeyBytes);
        final value = changes?[key];
        final revision = checks?[key];
        if (value != null && value.length > limits.maxValueBytes) {
          throw ArgumentError('Value exceeds limit');
        }
        if (revision != null &&
            (revision.contextId <= 0 || revision.version <= 0)) {
          throw ArgumentError('Invalid revision');
        }
        total += encoded.length + (value?.length ?? 0);
        if (total > limits.maxOperationBytes) {
          throw ArgumentError('Operation exceeds byte limit');
        }
        inputs[i]
          ..key = _copy(arena, encoded)
          ..keySize = encoded.length
          ..value = value == null ? nullptr : _copy(arena, value)
          ..valueSize = value?.length ?? 0
          ..context = revision?.contextId ?? 0
          ..revision = revision?.version ?? 0
          ..action = changes == null || !changes.containsKey(key)
              ? 0
              : value == null
              ? 2
              : 1;
      }
      final output = arena<Pointer<native.NativeResult>>();
      final code = checks == null
          ? native.readStore(_handle, inputs, keys.length, output)
          : native.commitStore(_handle, inputs, keys.length, output);
      try {
        if (code == 1 && onConflict != null) return onConflict();
        _check(code);
        return decode(output.value.ref);
      } finally {
        if (output.value != nullptr) native.freeResult(output.value);
      }
    });
  }

  /// Releases this handle synchronously; repeated calls have no effect.
  ///
  /// The last handle destroys the context and its data. Reopening the same name
  /// then creates an empty store with a new context identity. [read] and [commit]
  /// throw [StateError] after close. A native finalizer is a fallback only and
  /// does not guarantee prompt cleanup when explicit close is omitted.
  void close() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    final handle = _handle;
    _handle = nullptr;
    native.closeStore(handle);
  }

  void _ensureOpen() {
    if (_handle == nullptr) throw StateError('Store is closed');
  }
}

Pointer<Uint8> _copy(Arena arena, List<int> bytes) {
  if (bytes.isEmpty) return nullptr;
  final p = arena<Uint8>(bytes.length);
  p.asTypedList(bytes.length).setAll(0, bytes);
  return p;
}

List<int> _encodeKey(String key, int limit) {
  if (key.isEmpty || key.contains('\u0000')) {
    throw ArgumentError('Keys must be nonempty and contain no NUL');
  }
  for (var i = 0; i < key.length; i++) {
    final c = key.codeUnitAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= key.length ||
          key.codeUnitAt(i) < 0xdc00 ||
          key.codeUnitAt(i) > 0xdfff) {
        throw ArgumentError('Malformed Unicode');
      }
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      throw ArgumentError('Malformed Unicode');
    }
  }
  // UTF-8 length is at least the number of UTF-16 units for valid text.
  if (key.length > limit) throw ArgumentError('Key exceeds limit');
  final bytes = utf8.encode(key);
  if (bytes.length > limit) throw ArgumentError('Key exceeds limit');
  return bytes;
}

void _check(int code) {
  if (code == 0) return;
  throw SharedStoreException(switch (code) {
    2 => SharedStoreError.invalidInput,
    3 => SharedStoreError.limitExceeded,
    4 => SharedStoreError.configurationMismatch,
    5 => SharedStoreError.allocationFailed,
    6 => SharedStoreError.revisionExhausted,
    _ => SharedStoreError.nativeFailure,
  });
}
