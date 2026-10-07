#include "common/log.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr std::uintmax_t kMaxLogBytes = 8ull * 1024ull * 1024ull;
int failures = 0;

void expect(bool condition, const char* name) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", name);
        ++failures;
    }
}

void remove_log() {
    std::error_code ec;
    std::filesystem::remove("twdll.log", ec);
}

std::string read_log() {
    std::ifstream in("twdll.log", std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

void write_prefill(std::uintmax_t bytes) {
    std::ofstream out("twdll.log", std::ios::binary | std::ios::trunc);
    std::string block(64 * 1024, 'P');
    while (bytes > 0) {
        const size_t count = static_cast<size_t>(std::min<std::uintmax_t>(bytes, block.size()));
        out.write(block.data(), static_cast<std::streamsize>(count));
        bytes -= count;
    }
}

} // namespace

int main() {
    remove_log();

    Log("hello %d", 42);
    expect(read_log() == "hello 42\n", "basic formatted append");

    remove_log();
    const std::string oversized(6000, 'X');
    Log("%s", oversized.c_str());
    const std::string truncated = read_log();
    expect(truncated.size() <= 4096, "oversized message stays within one-line budget");
    expect(truncated.find(" [truncated]") != std::string::npos, "oversized message carries truncation marker");
    expect(!truncated.empty() && truncated.back() == '\n', "oversized message remains newline terminated");

    remove_log();
    constexpr int kThreads = 8;
    constexpr int kLinesPerThread = 250;
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([t, kLinesPerThread]() {
            for (int i = 0; i < kLinesPerThread; ++i) {
                Log("thread=%d seq=%d", t, i);
            }
        });
    }
    for (auto& thread : threads) {
        thread.join();
    }
    const std::string concurrent = read_log();
    const size_t newlines = static_cast<size_t>(std::count(concurrent.begin(), concurrent.end(), '\n'));
    expect(newlines == static_cast<size_t>(kThreads * kLinesPerThread),
           "concurrent logging preserves every bounded line");
    expect(std::filesystem::file_size("twdll.log") < kMaxLogBytes,
           "concurrent logging remains below file budget");

    remove_log();
    const std::uintmax_t initial_size = kMaxLogBytes - 8;
    write_prefill(initial_size);
    Log("0123456789ABCDEF");
    const std::uintmax_t capped_size = std::filesystem::file_size("twdll.log");
    expect(capped_size == kMaxLogBytes, "near-budget append caps exactly at 8 MiB");
    {
        std::ifstream in("twdll.log", std::ios::binary);
        char first = '\0';
        in.get(first);
        expect(first == 'P', "budget handling never truncates existing evidence");
    }

    Log("must not grow");
    expect(std::filesystem::file_size("twdll.log") == capped_size,
           "full log budget fails soft without further growth");

    remove_log();

    if (failures == 0) {
        std::puts("twdll log tests: PASS (format, truncation, concurrency, 8 MiB cap)");
        return 0;
    }

    std::fprintf(stderr, "twdll log tests: %d failure(s)\n", failures);
    return 1;
}
