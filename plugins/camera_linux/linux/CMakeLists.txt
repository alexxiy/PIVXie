# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "camera_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Libraries bundled with the app: just this one. A static OpenCV is linked
# into it; a system OpenCV stays a system dependency (../src/CMakeLists.txt).
set(camera_linux_bundled_libraries
  $<TARGET_FILE:camera_linux>
  PARENT_SCOPE
)
