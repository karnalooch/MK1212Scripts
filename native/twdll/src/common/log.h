#pragma once

#include <string>

// Logs a formatted message to twdll.log.
// Diagnostics are fail-soft, capped at 8 MiB per file, and each line is bounded.
void Log(const char* format, ...);

// Logs a simple string.
void Log(const std::string& message);
