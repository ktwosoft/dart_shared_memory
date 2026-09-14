import 'dart:typed_data';

/// Resource limits shared by every handle attached to one named store.
///
/// Validation occurs when opening a store. All values must be positive.
/// [maxValueBytes] and [maxOperationBytes] cannot exceed [maxBytes]. Existing
/// stores require an exact match for every limit when another handle attaches.
///
/// Native accounting includes conservative metadata allowances; it is not an
/// exact bound on allocator overhead, process RSS, or the Dart heap.
final class StoreLimits {
  /// Creates limits with a 64 MiB native budget and an 8 MiB value limit.
  const StoreLimits({
    this.maxBytes = 64 * 1024 * 1024,
    this.maxEntries = 100000,
    this.maxValueBytes = 8 * 1024 * 1024,
    this.maxKeysPerOperation = 1024,
    this.maxKeyBytes = 1024,
    this.maxOperationBytes = 16 * 1024 * 1024,
  });

  /// Native charged-byte budget, including live, staged, pinned and result data.
  ///
  /// At most `(2^63 - 1) ~/ 1024`. Replacement and reads need spare capacity
  /// beyond the stored payloads. Dart input and output copies are additional.
  final int maxBytes;

  /// Maximum number of live entries, up to 10,000,000.
  final int maxEntries;

  /// Maximum bytes in one value. Empty values are permitted.
  final int maxValueBytes;

  /// Maximum distinct keys in one read or commit, up to 65,536.
  ///
  /// A commit counts every precondition, including keys that are only checked.
  final int maxKeysPerOperation;

  /// Maximum UTF-8 bytes in one key, up to 65,536.
  ///
  /// Store names have a separate fixed limit of 4,096 UTF-8 bytes.
  final int maxKeyBytes;

  /// Maximum combined input key/value bytes per operation.
  ///
  /// The same limit applies separately to read-output payload bytes.
  final int maxOperationBytes;
}

/// An equality token identifying a live entry revision within a store lifetime.
///
/// Obtain tokens from reads or successful commits. Reconstructing an existing
/// token for isolate messaging is supported; inventing tokens is not. Tokens
/// reject stale writes after entry deletion/recreation or store recreation.
/// They are neither timestamps nor security credentials.
final class EntryRevision {
  /// Reconstructs a token from its original [contextId] and [version].
  const EntryRevision(this.contextId, this.version);

  /// Identity of the native store lifetime that issued this token.
  final int contextId;

  /// Positive revision number allocated within that store lifetime.
  ///
  /// Numbers never wrap; gaps are allowed. Compare tokens for equality rather
  /// than interpreting revision differences as an update count.
  final int version;

  @override
  bool operator ==(Object other) =>
      other is EntryRevision &&
      contextId == other.contextId &&
      version == other.version;

  @override
  int get hashCode => Object.hash(contextId, version);
}

/// Bytes and a revision captured together by a store read.
///
/// Store-returned snapshots contain copied, Dart-owned bytes. Mutating those
/// bytes does not modify native state; submit a conditional commit to write them.
final class EntrySnapshot {
  /// Pairs [value] with [revision] without making another copy of [value].
  const EntrySnapshot({required this.value, required this.revision});

  /// Mutable bytes owned by the caller, including a possible empty value.
  final Uint8List value;

  /// Revision captured alongside [value], suitable for a commit precondition.
  final EntryRevision revision;
}

/// Outcome of an atomic conditional commit.
///
/// A conflict is an expected outcome: [committed] is false, [revisions] is empty,
/// and none of the requested changes were applied by that call.
final class CommitResult {
  /// Creates a result, making an unmodifiable copy of [revisions].
  CommitResult({
    required this.committed,
    required Map<String, EntryRevision?> revisions,
  }) : revisions = Map.unmodifiable(revisions);

  /// Whether every precondition matched and all changes were published.
  final bool committed;

  /// New revisions for changed keys only; null denotes a deleted entry.
  ///
  /// Unmodifiable and empty on conflict. Read-only preconditions are omitted.
  final Map<String, EntryRevision?> revisions;
}
