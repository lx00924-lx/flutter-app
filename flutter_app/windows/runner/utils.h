#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the C runtime and Win32 code. Creates a new console, or
// attaches to the parent process's console if there is one.
void CreateAndAttachConsole();

// Takes a UTF-8 string and returns a UTF-16 wide string.
std::wstring Utf16FromUtf8(const std::string& utf8_string);

// Takes a null-terminated UTF-8 string and returns a UTF-16 wide string.
std::wstring Utf16FromUtf8(const char* utf8_string);

// Takes a UTF-16 wide string and returns a UTF-8 string.
std::string Utf8FromUtf16(const std::wstring& utf16_string);

// Takes a null-terminated UTF-16 wide string and returns a UTF-8 string.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
