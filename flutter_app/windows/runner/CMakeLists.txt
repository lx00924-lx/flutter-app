cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Run the Flutter tool to generate the plugin registrants.
# If FLUTTER_MANAGED_DIR is not set, fallback to flutter/ephemeral
if(NOT DEFINED FLUTTER_MANAGED_DIR)
  set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral")
endif()

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not here.
add_executable(${BINARY_NAME} WIN32
  "main.cpp"
  "my_application.cpp"
  "my_application.h"
  "resource.h"
  "runner.exe.manifest"
  "Runner.rc"
  "utils.cpp"
  "utils.h"
  "win32_window.cpp"
  "win32_window.h"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool to generate the plugin registrants.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only errors and warnings are printed by default.
target_compile_definitions(${BINARY_NAME} PRIVATE
  "_UNICODE"
  "UNICODE"
)
