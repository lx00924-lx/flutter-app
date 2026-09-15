#include "my_application.h"

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

MyApplication::MyApplication() {}

MyApplication::~MyApplication() {}

bool MyApplication::CreateAndShow() {
  if (!Create(L"LxAI", Point(10, 10), Size(1280, 800))) {
    return false;
  }
  SetQuitOnClose(true);

  RECT frame = GetBounds();
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project);

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  return true;
}

LRESULT
MyApplication::MessageHandler(HWND hwnd,
                              UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->view()->HandleTopLevelWindowProc(hwnd, message,
                                                             wparam, lparam);
    if (result) {
      return *result;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
