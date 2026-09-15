# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(flutter_app LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "LxAI")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0079 NEW)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Options configuring C++ compiler warnings.
if(MSVC)
  add_compile_options(
    /W4 /WX /wd"4100" /wd"4127" /wd"4244" /wd"4251" /wd"4275" /wd"4458"
    /wd"4702" /wd"4996"
  )
endif()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Generated code build; see flutter/CMakeLists.txt.
add_subdirectory("flutter")

# For visual studio solutions, set the project startup project
set_property(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" PROPERTY VS_STARTUP_PROJECT "${BINARY_NAME}")
