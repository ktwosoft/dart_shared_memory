// Native harness includes the implementation to inject pre-publication failures.
#define SS_TESTING
#include "../shared_store.cpp"
#include <cassert>
#include <iostream>
#include <thread>

SSLimits limits{64 * 1024 * 1024, 10000, 1024 * 1024, 1024, 1024, 4 * 1024 * 1024};
void *open(const char *name) {
  void *h = nullptr;
  assert(ss_open(reinterpret_cast<const uint8_t *>(name), strlen(name), &limits, &h) == 0);
  return h;
}
SSInput input(const char *key, int action = 0, int64_t value = 0, int64_t ctx = 0,
              int64_t rev = 0) {
  // Value is installed by callers; never return pointer to local stack.
  (void)value;
  return {reinterpret_cast<const uint8_t *>(key),
          static_cast<int64_t>(strlen(key)),
          nullptr,
          0,
          ctx,
          rev,
          action};
}
int main() {
  auto h = open("native");
  SSResult *out = nullptr;
  uint8_t value = 42;
  SSInput create[2] = {input("a", 1), input("b", 1)};
  for (auto &i : create) {
    i.value = &value;
    i.value_size = 1;
  }
  // Every injected allocation failure leaves both keys absent and budget restored.
  for (int fail = 0; fail < 9; fail++) {
    fail_after = fail;
    int code = ss_commit(h, create, 2, &out);
    fail_after = -1;
    if (code == 0) {
      ss_result_free(out);
      break;
    }
    assert(code == 5 && out == nullptr);
    assert(context(h)->entries.empty());
    assert(context(h)->budget->used == 0);
  }
  if (context(h)->entries.empty()) {
    assert(ss_commit(h, create, 2, &out) == 0);
    ss_result_free(out);
  }
  SSInput read[2] = {input("a"), input("b")};
  assert(ss_read(h, read, 2, &out) == 0);
  SSInput remove[2] = {input("a", 2, 0, out->values[0].context, out->values[0].revision),
                       input("b", 2, 0, out->values[1].context, out->values[1].revision)};
  ss_result_free(out);
  assert(ss_commit(h, remove, 2, &out) == 0);
  ss_result_free(out);
  assert(context(h)->entries.empty());
  assert(context(h)->budget->used == 0);
  // Exhaustion fails before mutation.
  context(h)->revision = INT64_MAX;
  assert(ss_commit(h, create, 2, &out) == 6);
  assert(context(h)->entries.empty());
  context(h)->revision = 0;
  int64_t zero = 0;
  for (auto &i : create) {
    i.value = reinterpret_cast<uint8_t *>(&zero);
    i.value_size = 8;
  }
  assert(ss_commit(h, create, 2, &out) == 0);
  ss_result_free(out);
  std::atomic<int> conflicts{0};
  std::vector<std::thread> threads;
  for (int thread = 0; thread < 8; thread++)
    threads.emplace_back([&, thread] {
      auto own = open("native");
      for (int j = 0; j < 1000; j++)
        for (;;) {
          SSResult *snap = nullptr;
          assert(ss_read(own, read, 2, &snap) == 0);
          int64_t a, b;
          memcpy(&a, snap->values[0].value, 8);
          memcpy(&b, snap->values[1].value, 8);
          assert(a == b);
          auto first = thread % 2;
          SSInput changes[2];
          int64_t next = a + 1;
          for (int k = 0; k < 2; k++) {
            int i = (first + k) % 2;
            changes[k] =
                input(i == 0 ? "a" : "b", 1, 0, snap->values[i].context, snap->values[i].revision);
            changes[k].value = reinterpret_cast<uint8_t *>(&next);
            changes[k].value_size = 8;
          }
          ss_result_free(snap);
          int code = ss_commit(own, changes, 2, &snap);
          if (code == 1) {
            conflicts++;
            continue;
          }
          assert(code == 0);
          ss_result_free(snap);
          break;
        }
      ss_close(own);
    });
  for (auto &t : threads)
    t.join();
  assert(ss_read(h, read, 2, &out) == 0);
  int64_t count;
  memcpy(&count, out->values[0].value, 8);
  assert(count == 8000);
  ss_result_free(out);
  // Output pointers reset and invalid UTF-8 rejected at the ABI boundary.
  uint8_t bad[] = {0xed, 0xa0, 0x80};
  void *invalid = reinterpret_cast<void *>(1);
  assert(ss_open(bad, 3, &limits, &invalid) == 2 && invalid == nullptr);
  SSInput duplicate[2] = {read[0], read[0]};
  assert(ss_read(h, duplicate, 2, &out) == 2 && out == nullptr);
  ss_close(h);
  auto recreated = open("native");
  assert(ss_read(recreated, read, 2, &out) == 0 && out->values[0].revision == 0);
  ss_result_free(out);
  ss_close(recreated);
  std::cout << "native tests passed; conflicts=" << conflicts << "\n";
}
