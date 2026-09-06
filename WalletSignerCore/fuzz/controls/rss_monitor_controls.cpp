// Synthetic negative controls only. Never linked into signer or real targets.
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *, size_t) {
  const char *Mode = std::getenv("LOCUS_RUST_MONITOR_CONTROL");
  if (!Mode || std::strcmp(Mode, "clean") == 0)
    return 0;
  if (std::strcmp(Mode, "leak") == 0) {
    // Volatile writes keep the intentionally lost allocation observable.
    volatile auto *Bytes = static_cast<unsigned char *>(std::malloc(4096));
    if (!Bytes) std::abort();
    Bytes[0] = 1;
    return 0;
  }
  if (std::strcmp(Mode, "crash") == 0)
    std::abort();
  if (std::strcmp(Mode, "timeout") == 0) {
    for (;;) std::this_thread::sleep_for(std::chrono::seconds(1));
  }
  if (std::strcmp(Mode, "rss") == 0) {
    constexpr size_t Size = 256 * 1024 * 1024;
    volatile auto *Bytes = static_cast<unsigned char *>(std::malloc(Size));
    if (!Bytes) std::abort();
    for (size_t Index = 0; Index < Size; Index += 4096) Bytes[Index] = 1;
    // The malloc limit exceeds this allocation; the RSS monitor must fail.
    std::this_thread::sleep_for(std::chrono::seconds(3));
    std::free(const_cast<unsigned char *>(Bytes));
    return 0;
  }
  std::abort();
}
