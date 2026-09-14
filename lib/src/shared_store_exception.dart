/// Native store failure categories, excluding ordinary commit conflicts.
///
/// Dart-side argument validation uses [ArgumentError]; using a closed handle
/// uses [StateError]. These categories describe failures reported at the native
/// boundary or a mismatch between the bindings and the loaded library.
enum SharedStoreError {
  /// The native boundary rejected an argument or limit configuration.
  invalidInput,

  /// A configured entry, operation, or charged-memory limit was exceeded.
  limitExceeded,

  /// A same-name store is already open with different limits.
  configurationMismatch,

  /// A native allocation failed, even if configured capacity remained.
  allocationFailed,

  /// The native context or revision counter cannot issue another unique token.
  revisionExhausted,

  /// An unexpected native failure occurred.
  nativeFailure,

  /// The loaded native library uses an unsupported ABI version.
  abiMismatch,
}

/// A failure reported by the native store or its ABI compatibility check.
///
/// A native commit failure before publication leaves its requested changes
/// unapplied. This does not cover failures delivering an already committed result
/// to Dart. Commit conflicts are returned as results rather than thrown.
final class SharedStoreException implements Exception {
  /// Creates an exception carrying a stable failure category.
  const SharedStoreException(this.error);

  /// The failure category; [toString] is intended for diagnostics.
  final SharedStoreError error;

  @override
  String toString() => 'SharedStoreException: ${error.name}';
}
