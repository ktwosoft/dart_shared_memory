## 0.1.1

- Restore `code_assets` 1.x compatibility for Flutter macOS applications using
  `objective_c`, with a compatible native C toolchain.
- Allow hook and toolchain versions compatible with Flutter’s pinned `meta`
  dependency, without application-level version overrides.

## 0.1.0

- Named native contexts shared across isolates.
- Copied, consistent batch reads and atomic conditional batch commits.
- Per-entry locking, revision guards and bounded native allocation accounting.
- Native-assets build, explicit close and native finalizer backstop.
- Documented public API, resource limits, error handling and isolate lifecycle.
- Runnable single-isolate and multi-isolate examples.
- Initial validated platform: macOS arm64 with Dart 3.12 or later.
