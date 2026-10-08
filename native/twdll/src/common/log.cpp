#include "log.h"
#include <algorithm>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <mutex>
#include <windows.h>
#include <share.h>

static std::mutex g_log_mutex;
static const char* LOG_FILE = "twdll.log";
static constexpr __int64 MAX_LOG_BYTES = 8LL * 1024LL * 1024LL;
static constexpr size_t MAX_LOG_LINE_BYTES = 4096;

void Log(const char* format, ...) {
    if (!format) return;

    char line[MAX_LOG_LINE_BYTES] = {};
    va_list args;
    va_start(args, format);
    int required = vsnprintf(line, sizeof(line), format, args);
    va_end(args);

    if (required < 0) {
        return;
    }

    const bool line_truncated = static_cast<size_t>(required) >= sizeof(line);
    if (line_truncated) {
        static constexpr char marker[] = " [truncated]";
        constexpr size_t marker_len = sizeof(marker) - 1;
        const size_t marker_pos = sizeof(line) - 1 - marker_len;
        memcpy(line + marker_pos, marker, marker_len);
        line[sizeof(line) - 1] = '\0';
    }

    const size_t line_len = strlen(line);
    std::lock_guard<std::mutex> lock(g_log_mutex);

    FILE* f = _fsopen(LOG_FILE, "a+b", _SH_DENYNO);
    if (!f) {
        return;
    }

    if (_fseeki64(f, 0, SEEK_END) != 0) {
        fclose(f);
        return;
    }

    const __int64 current_size = _ftelli64(f);
    if (current_size < 0 || current_size >= MAX_LOG_BYTES) {
        fclose(f);
        return;
    }

    const __int64 remaining = MAX_LOG_BYTES - current_size;
    if (remaining <= 1) {
        fclose(f);
        return;
    }

    const size_t writable = static_cast<size_t>(std::min<__int64>(
        static_cast<__int64>(line_len), remaining - 1));
    if (writable > 0) {
        fwrite(line, 1, writable, f);
    }
    fputc('\n', f);
    fclose(f);
}

void Log(const std::string& message) {
    Log("%s", message.c_str());
}
