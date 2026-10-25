#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ── 单实例保护（必须有）────────────────────────────────────────────
  //
  // 本 App 的本地数据（Hive 的 settings/messages/sessions 三个 box）是
  // **单文件、无跨进程锁**的。同时开两个实例的代价，2026-10-25 实测过：
  //
  //   1. 两个实例往同一份 Hive 写 → 互相覆盖，写出重复或空白消息；
  //   2. 各自触发一次登录、各带各的 clientSessionId → 服务端槽位被反复改写，
  //      最后总有一台的凭证"无主" → 它的每个同步请求都被 403 拦下 →
  //      消息同步静默失效几个小时，而界面上还显示"已登录"；
  //   3. 同一个 token 还会各自拉起一个桥接进程，两个桥接互踢。
  //
  // 所以这里用命名互斥体拦住第二个实例。名字用固定前缀即可，不带用户名：
  // 同一台机器上双击第二份就该被拒绝。
  //
  // 注意 `GetLastError()` 必须在任何其它 Win32 调用之前读，否则会被覆盖。
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"LxAI-Desktop-SingleInstance");
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(single_instance_mutex);
    // 把已经开着的那一个提到前台 —— 让用户知道"它已经在运行"，
    // 而不是双击之后什么都不发生（那会被当成没启动）。
    HWND existing = ::FindWindowW(nullptr, L"LxAI");
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      } else {
        ::ShowWindow(existing, SW_SHOW);
      }
      ::SetForegroundWindow(existing);
    } else {
      ::MessageBoxW(nullptr, L"LxAI 已经在运行中了。", L"LxAI",
                    MB_OK | MB_ICONINFORMATION);
    }
    return 0;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"LxAI", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
