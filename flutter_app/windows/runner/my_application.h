#ifndef RUNNER_MY_APPLICATION_H_
#define RUNNER_MY_APPLICATION_H_

#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

class MyApplication : public Win32Window {
 public:
  MyApplication();
  virtual ~MyApplication();

 private:
  // Win32Window:
  bool CreateAndShow();

 protected:
  // Win32Window:
  LRESULT MessageHandler(HWND window,
                         UINT const message,
                         WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  friend int APIENTRY wWinMain(_In_ HINSTANCE instance,
                               _In_opt_ HINSTANCE prev_instance,
                               _In_ wchar_t *command_line,
                               _In_ int show_command);
};

#endif  // RUNNER_MY_APPLICATION_H_
