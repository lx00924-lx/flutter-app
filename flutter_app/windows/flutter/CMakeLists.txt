# CMake project that writes Flutter-specific build targets.
cmake_minimum_required(VERSION 3.14)
project(flutter_wrapper LANGUAGES CXX)

# This value is used when generating builds using this file, and it must not
# be changed
set(WRAPPER_ROOT "${CMAKE_CURRENT_SOURCE_DIR}")

# === Flutter configuration ====================================================

# Look for the generated config file in the build directory. If it's not found,
# use the default.
set(FLUTTER_CONFIG_FILE "${CMAKE_BINARY_DIR}/flutter/ephemeral/generated_config.cmake")
if(EXISTS "${FLUTTER_CONFIG_FILE}")
  include("${FLUTTER_CONFIG_FILE}")
else()
  # Default values when the build hasn't run yet.
  set(FLUTTER_EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")
endif()

# Set up the library files that need to be copied.
set(FLUTTER_LIBRARY "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll")
set(FLUTTER_PLUGIN_SYMLINK_DIR "${CMAKE_BINARY_DIR}/plugins")

# Ensure apply_standard_settings is defined
if(NOT COMMAND apply_standard_settings)
  function(apply_standard_settings TARGET)
    target_compile_features(${TARGET} PUBLIC cxx_std_17)
  endfunction()
endif()

# === Target configuration =====================================================

# The Flutter wrapper library.
#
# This wrapper hides the platform-specific details of the Flutter C API.
set(WRAPPER_SOURCES
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/core_implementations.cc"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/standard_codec.cc"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/plugin_registrar.cc"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/flutter_engine.cc"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/flutter_view_controller.cc"
)

add_library(flutter_wrapper_plugin INTERFACE)
target_include_directories(flutter_wrapper_plugin INTERFACE
  "${FLUTTER_EPHEMERAL_DIR}"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include"
)

add_library(flutter_wrapper_app STATIC
  ${WRAPPER_SOURCES}
)
apply_standard_settings(flutter_wrapper_app)
set_target_properties(flutter_wrapper_app PROPERTIES
  POSITION_INDEPENDENT_CODE ON)
target_include_directories(flutter_wrapper_app PUBLIC
  "${FLUTTER_EPHEMERAL_DIR}"
  "${FLUTTER_EPHEMERAL_DIR}/cpp_client_wrapper/include"
)
target_link_libraries(flutter_wrapper_app PUBLIC
  "${FLUTTER_EPHEMERAL_DIR}/flutter_windows.dll.lib"
)

# === Package-level support ====================================================

# Helper function to copy files to the output directory.
function(flutter_copy_file TARGET SOURCE DESTINATION)
  add_custom_command(
    TARGET ${TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      ${SOURCE}
      ${DESTINATION}
  )
endfunction()
