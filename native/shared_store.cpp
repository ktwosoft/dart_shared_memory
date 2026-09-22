#include "shared_store_api.h"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>
#include <string>
#include <vector>

namespace {
struct Failure {
  int code;
};
void require(bool b, int code = 2) {
  if (!b)
    throw Failure{code};
}
#ifdef SS_TESTING
thread_local int fail_after = -1;
void checkpoint() {
  if (fail_after == 0)
    throw std::bad_alloc();
  if (fail_after > 0)
    --fail_after;
}
#else
void checkpoint() {}
#endif
bool utf8(const uint8_t *p, int64_t n) {
  if (!p || n <= 0)
    return false;
  for (int64_t i = 0; i < n;) {
    uint32_t c = p[i++];
    if (c == 0)
      return false;
    if (c < 128)
      continue;
    int extra;
    uint32_t minimum;
    if (c >= 0xc2 && c <= 0xdf) {
      extra = 1;
      minimum = 0x80;
      c &= 31;
    } else if (c >= 0xe0 && c <= 0xef) {
      extra = 2;
      minimum = 0x800;
      c &= 15;
    } else if (c >= 0xf0 && c <= 0xf4) {
      extra = 3;
      minimum = 0x10000;
      c &= 7;
    } else
      return false;
    if (n - i < extra)
      return false;
    while (extra--) {
      auto b = p[i++];
      if ((b & 0xc0) != 0x80)
        return false;
      c = (c << 6) | (b & 63);
    }
    if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
      return false;
  }
  return true;
}

struct Budget {
  const int64_t limit;
  std::atomic<int64_t> used{0};
  explicit Budget(int64_t n) : limit(n) {}
  void take(int64_t n) {
    require(n >= 0, 3);
    auto current = used.load();
    do {
      require(n <= limit - current, 3);
    } while (!used.compare_exchange_weak(current, current + n));
  }
};

struct Charge {
  std::shared_ptr<Budget> budget;
  int64_t size;
  Charge(std::shared_ptr<Budget> b, int64_t n) : budget(std::move(b)), size(n) { budget->take(n); }
  ~Charge() { budget->used.fetch_sub(size); }
  Charge(const Charge &) = delete;
};

struct Blob {
  Charge charge;
  std::vector<uint8_t> bytes;
  Blob(std::shared_ptr<Budget> b, const uint8_t *p, int64_t n) : charge(b, n + 64) {
    checkpoint();
    if (n)
      bytes.assign(p, p + n);
  }
};

struct Entry {
  Charge charge;
  std::shared_mutex mutex;
  int64_t revision = 0;
  std::shared_ptr<Blob> blob;
  Entry(std::shared_ptr<Budget> b, int64_t keyBytes) : charge(b, keyBytes + 256) {}
};

using Directory = std::map<std::string, std::shared_ptr<Entry>>;

struct Context {
  SSLimits limits;
  int64_t id;
  std::atomic<int64_t> revision{0};
  std::shared_ptr<Budget> budget;
  std::shared_mutex directory_mutex;
  Directory entries;
  Context(SSLimits l, int64_t i)
      : limits(l), id(i), budget(std::make_shared<Budget>(l.max_bytes)) {}
};

struct Handle {
  std::shared_ptr<Context> context;
};

std::mutex registry_mutex;
std::map<std::string, std::weak_ptr<Context>> registry;
int64_t next_context = 0;

bool same(SSLimits a, SSLimits b) {
  return a.max_bytes == b.max_bytes && a.max_entries == b.max_entries &&
         a.max_value == b.max_value && a.max_keys == b.max_keys && a.max_key == b.max_key &&
         a.max_operation == b.max_operation;
}

struct Result : SSResult {
  Charge charge;
  std::vector<SSValue> records;
  std::vector<uint8_t> data;
  Result(std::shared_ptr<Budget> budget, int64_t n, int64_t bytes)
      : charge(budget, 128 + n * 32 + bytes) {
    checkpoint();
    records.resize(n);
    data.resize(bytes);
    count = n;
    values = records.data();
  }
};

struct KeysResult : SSKeysResult {
  Charge charge;
  std::vector<SSKey> records;
  std::vector<uint8_t> data;
  KeysResult(std::shared_ptr<Budget> budget, int64_t n, int64_t bytes)
      : charge(budget, 128 + n * 32 + bytes) {
    checkpoint();
    records.resize(n);
    data.resize(bytes);
    count = n;
    keys = records.data();
  }
};

std::shared_ptr<Context> context(void *h) {
  require(h != nullptr);
  return static_cast<Handle *>(h)->context;
}

void validate_limits(const SSLimits &l) {
  const int64_t bound = std::numeric_limits<int64_t>::max() / 1024;
  require(l.max_bytes > 0 && l.max_bytes <= bound && l.max_entries > 0 &&
          l.max_entries <= 10000000);
  require(l.max_value > 0 && l.max_value <= l.max_bytes && l.max_keys > 0 && l.max_keys <= 65536);
  require(l.max_key > 0 && l.max_key <= 65536 && l.max_operation > 0 &&
          l.max_operation <= l.max_bytes);
}

struct Request {
  Charge charge;
  std::unique_ptr<Charge> key_charge;
  std::vector<std::string> keys;
  std::vector<size_t> order;

  Request(Context &c, const SSInput *in, int64_t n, bool commit)
      : charge(c.budget, 128 + std::max<int64_t>(0, n) * 512) {
    require(n >= 0 && n <= c.limits.max_keys && (n == 0 || in));
    require(!commit || n > 0);
    int64_t total = 0, key_bytes = 0;
    int changed = 0;
    for (int64_t i = 0; i < n; i++) {
      require(in[i].key_size > 0 && in[i].key_size <= c.limits.max_key &&
              utf8(in[i].key, in[i].key_size));
      require(in[i].value_size >= 0 && in[i].value_size <= c.limits.max_value);
      require(in[i].value_size == 0 || in[i].value);
      require(in[i].action >= 0 && in[i].action <= 2 && in[i].revision >= 0 && in[i].context >= 0);
      require(!commit || ((in[i].revision == 0) == (in[i].context == 0)));
      require(in[i].action != 2 || in[i].revision > 0);
      require(in[i].action == 1 || in[i].value_size == 0);
      require(commit || in[i].action == 0);
      const auto bytes = in[i].key_size + in[i].value_size;
      require(bytes <= c.limits.max_operation - total, 3);
      total += bytes;
      key_bytes += in[i].key_size;
      changed += in[i].action != 0;
    }
    require(!commit || changed > 0);
    key_charge = std::make_unique<Charge>(c.budget, key_bytes);
    checkpoint();
    keys.reserve(n);
    order.reserve(n);
    for (int64_t i = 0; i < n; i++) {
      keys.emplace_back(reinterpret_cast<const char *>(in[i].key), in[i].key_size);
      order.push_back(i);
    }
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return keys[a] < keys[b]; });
    for (size_t i = 1; i < order.size(); i++)
      require(keys[order[i - 1]] != keys[order[i]]);
  }
};

template <class F> int32_t boundary(F f) {
  try {
    f();
    return 0;
  } catch (Failure e) {
    return e.code;
  } catch (const std::bad_alloc &) {
    return 5;
  } catch (...) {
    return 7;
  }
}
} // namespace
extern "C" {
int32_t ss_abi_version() { return 1; }

int32_t ss_open(const uint8_t *name, int64_t n, const SSLimits *limits, void **out) {
  if (out)
    *out = nullptr;
  return boundary([&] {
    require(out && limits);
    validate_limits(*limits);
    require(n <= 4096 && utf8(name, n));
    std::string key(reinterpret_cast<const char *>(name), n);
    std::lock_guard<std::mutex> lock(registry_mutex);
    for (auto it = registry.begin(); it != registry.end();)
      if (it->second.expired())
        it = registry.erase(it);
      else
        ++it;
    auto it = registry.find(key);
    auto c = it == registry.end() ? nullptr : it->second.lock();
    if (c)
      require(same(c->limits, *limits), 4);
    else {
      require(next_context < INT64_MAX, 6);
      checkpoint();
      c = std::make_shared<Context>(*limits, ++next_context);
      registry[key] = c;
    }
    checkpoint();
    *out = new Handle{std::move(c)};
  });
}

void ss_close(void *handle) { delete static_cast<Handle *>(handle); }

void ss_result_free(SSResult *result) { delete static_cast<Result *>(result); }

void ss_keys_result_free(SSKeysResult *result) { delete static_cast<KeysResult *>(result); }

int32_t ss_keys(void *handle, const uint8_t *prefix, int64_t n, SSKeysResult **out) {
  if (out)
    *out = nullptr;
  return boundary([&] {
    require(out);
    auto c = context(handle);
    require(n >= 0 && n <= c->limits.max_key &&
            (n == 0 || utf8(prefix, n)));
    const std::string start(n == 0 ? "" : reinterpret_cast<const char *>(prefix), n);
    std::shared_lock<std::shared_mutex> directory(c->directory_mutex);
    int64_t count = 0;
    int64_t bytes = 0;
    auto first = c->entries.lower_bound(start);
    for (auto it = first; it != c->entries.end(); ++it) {
      const auto &key = it->first;
      if (key.compare(0, start.size(), start) != 0)
        break;
      require(count < c->limits.max_keys, 3);
      require(static_cast<int64_t>(key.size()) <= c->limits.max_operation - bytes, 3);
      count++;
      bytes += key.size();
    }
    auto result = std::make_unique<KeysResult>(c->budget, count, bytes);
    int64_t offset = 0;
    size_t index = 0;
    for (auto it = first; it != c->entries.end(); ++it) {
      const auto &key = it->first;
      if (key.compare(0, start.size(), start) != 0)
        break;
      auto &item = result->records[index++];
      item.size = key.size();
      item.key = result->data.data() + offset;
      std::memcpy(result->data.data() + offset, key.data(), key.size());
      offset += key.size();
    }
    *out = result.release();
  });
}

int32_t ss_read(void *handle, const SSInput *in, int64_t n, SSResult **out) {
  if (out)
    *out = nullptr;
  return boundary([&] {
    require(out);
    auto c = context(handle);
    require(n >= 0 && n <= c->limits.max_keys);
    Request req(*c, in, n, false);
    std::vector<std::shared_ptr<Blob>> snapshots(n);
    std::vector<int64_t> revisions(n);
    int64_t bytes = 0;
    {
      std::shared_lock<std::shared_mutex> directory(c->directory_mutex);
      std::vector<std::shared_lock<std::shared_mutex>> locks;
      locks.reserve(n);
      for (auto i : req.order) {
        auto it = c->entries.find(req.keys[i]);
        if (it != c->entries.end())
          locks.emplace_back(it->second->mutex);
      }
      for (size_t i = 0; i < req.keys.size(); i++) {
        auto it = c->entries.find(req.keys[i]);
        if (it == c->entries.end())
          continue;
        snapshots[i] = it->second->blob;
        revisions[i] = it->second->revision;
        require(static_cast<int64_t>(snapshots[i]->bytes.size()) <= c->limits.max_operation - bytes,
                3);
        bytes += snapshots[i]->bytes.size();
      }
    }
    auto result = std::make_unique<Result>(c->budget, n, bytes);
    size_t offset = 0;
    for (int64_t i = 0; i < n; i++) {
      auto &r = result->records[i];
      r.context = c->id;
      r.revision = revisions[i];
      if (snapshots[i]) {
        r.size = snapshots[i]->bytes.size();
        if (r.size) {
          r.value = result->data.data() + offset;
          std::memcpy(result->data.data() + offset, snapshots[i]->bytes.data(), r.size);
          offset += r.size;
        }
      }
    }
    *out = result.release();
  });
}

int32_t ss_commit(void *handle, const SSInput *in, int64_t n, SSResult **out) {
  if (out)
    *out = nullptr;
  return boundary([&] {
    require(out);
    auto c = context(handle);
    require(n > 0 && n <= c->limits.max_keys);
    Request req(*c, in, n, true);
    Directory staged;
    std::vector<std::shared_ptr<Blob>> blobs(n);
    bool structural = false;
    int64_t changes = 0;
    // Prepare all allocations, including result metadata, before publication.
    for (int64_t i = 0; i < n; i++) {
      structural |= in[i].action == 2 || (in[i].action == 1 && in[i].revision == 0);
      if (in[i].action)
        changes++;
      if (in[i].action == 1) {
        checkpoint();
        blobs[i] = std::make_shared<Blob>(c->budget, in[i].value, in[i].value_size);
        if (in[i].revision == 0) {
          checkpoint();
          staged.emplace(req.keys[i], std::make_shared<Entry>(c->budget, in[i].key_size));
        }
      }
    }
    auto result = std::make_unique<Result>(c->budget, n, 0);
    std::unique_lock<std::shared_mutex> exclusive(c->directory_mutex, std::defer_lock);
    std::shared_lock<std::shared_mutex> shared(c->directory_mutex, std::defer_lock);
    if (structural)
      exclusive.lock();
    else
      shared.lock();
    std::vector<std::shared_ptr<Entry>> retained;
    retained.reserve(n);
    std::vector<std::unique_lock<std::shared_mutex>> locks;
    locks.reserve(n);
    for (auto i : req.order) {
      auto it = c->entries.find(req.keys[i]);
      if (it != c->entries.end()) {
        retained.push_back(it->second);
        locks.emplace_back(it->second->mutex);
      }
    }
    int64_t count = c->entries.size();
    for (int64_t i = 0; i < n; i++) {
      auto it = c->entries.find(req.keys[i]);
      bool found = it != c->entries.end();
      if (in[i].revision == 0)
        require(!found, 1);
      else
        require(found && in[i].context == c->id && it->second->revision == in[i].revision, 1);
      if (in[i].action == 1 && !found)
        count++;
      if (in[i].action == 2)
        count--;
    }
    require(count <= c->limits.max_entries, 3);
    auto rev = c->revision.load();
    do {
      require(changes <= INT64_MAX - rev, 6);
    } while (!c->revision.compare_exchange_weak(rev, rev + changes));
    // No allocations or throwing work after this point. std::map node insertion
    // reuses staged nodes; the byte-string comparator does not throw.
    for (int64_t i = 0; i < n; i++) {
      auto &r = result->records[i];
      r.context = c->id;
      auto it = c->entries.find(req.keys[i]);
      if (in[i].action == 2) {
        ++rev;
        c->entries.erase(it);
        r.revision = 0;
      } else if (in[i].action == 1) {
        if (it == c->entries.end()) {
          auto node = staged.extract(req.keys[i]);
          it = c->entries.insert(std::move(node)).position;
        }
        it->second->blob = std::move(blobs[i]);
        it->second->revision = ++rev;
        r.revision = rev;
      } else if (it != c->entries.end())
        r.revision = it->second->revision;
    }
    *out = result.release();
  });
}
}
