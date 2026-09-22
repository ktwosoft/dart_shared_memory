#ifndef SHARED_STORE_API_H
#define SHARED_STORE_API_H

#include <stdint.h>

#if defined(_WIN32)
#define SS_EXPORT __declspec(dllexport)
#else
#define SS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* C ABI version 1. Lengths/counts are signed 64-bit and must be nonnegative.
 * Inputs are borrowed for the duration of a synchronous call. Result buffers
 * belong to the library and must be released with ss_result_free, not free().
 * Concurrent access requires separately opened handles. Never close a handle
 * while it is in use. No C++ exception crosses this boundary.
 *
 * Status: 0 success; 1 commit conflict; 2 invalid input; 3 resource limit;
 * 4 incompatible limits; 5 allocation failed; 6 identity/revision exhausted;
 * 7 unexpected native failure. Failures before publication change no entries.
 */

/* Configuration must match exactly when attaching to a live named context. */
typedef struct {
  int64_t max_bytes, max_entries, max_value, max_keys, max_key, max_operation;
} SSLimits;

/* Key/value pointers refer to length-delimited bytes, not C strings.
 * Keys are nonempty strict UTF-8 without NUL. Empty values may use NULL.
 * For commits: action 0 checks only, 1 creates/replaces, 2 deletes.
 * context=revision=0 requires absence; positive pairs require a live revision.
 * Read requests use only the key fields (other fields should be zeroed).
 */
typedef struct {
  const uint8_t *key;
  int64_t key_size;
  const uint8_t *value;
  int64_t value_size;
  int64_t context, revision, action;
} SSInput;

/* A read value, or commit revision metadata. revision=0 denotes absence/deletion.
 * Value pointers remain valid only until their containing result is freed.
 */
typedef struct {
  const uint8_t *value;
  int64_t size, context, revision;
} SSValue;

/* One output per input key, in the original input order. */
typedef struct {
  int64_t count;
  const SSValue *values;
} SSResult;

/* Copied key names in bytewise sorted order. Key pointers live until freed. */
typedef struct {
  const uint8_t *key;
  int64_t size;
} SSKey;

typedef struct {
  int64_t count;
  const SSKey *keys;
} SSKeysResult;

/* Returns the ABI version expected by these declarations. */
SS_EXPORT int32_t ss_abi_version(void);

/* Attaches to a live named context or creates an empty one. On success, writes
 * an owning handle to out_handle. A non-NULL output slot is cleared on failure.
 */
SS_EXPORT int32_t ss_open(const uint8_t *name, int64_t name_size, const SSLimits *limits,
                          void **out_handle);

/* Releases a handle; NULL is allowed. A non-NULL handle may be closed only once.
 * Releasing the last handle destroys the context and its entries.
 */
SS_EXPORT void ss_close(void *handle);

/* Captures a consistent copied snapshot. out_result is cleared before work.
 * Free a successful result even when it contains no values.
 */
SS_EXPORT int32_t ss_read(void *handle, const SSInput *inputs, int64_t count,
                          SSResult **out_result);

/* Enumerates a consistent, bounded copy of keys matching a literal UTF-8
 * prefix. An empty prefix matches all keys. On limit failure there is no
 * partial result. Free success with ss_keys_result_free.
 */
SS_EXPORT int32_t ss_keys(void *handle, const uint8_t *prefix, int64_t prefix_size,
                          SSKeysResult **out_result);

/* Frees a returned key result. NULL is allowed. */
SS_EXPORT void ss_keys_result_free(SSKeysResult *result);

/* Validates every precondition and publishes every change or none. Successful
 * output contains revision metadata; conflict returns 1 and no result.
 */
SS_EXPORT int32_t ss_commit(void *handle, const SSInput *inputs, int64_t count,
                            SSResult **out_result);

/* Frees a returned result and its buffers. NULL is allowed. */
SS_EXPORT void ss_result_free(SSResult *result);

#ifdef __cplusplus
}
#endif
#endif
