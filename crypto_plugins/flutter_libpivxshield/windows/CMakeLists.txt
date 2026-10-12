# Builds the Rust crate in ../rust with cargokit; Flutter bundles the
# resulting library next to the app (an FFI plugin, no C++ side).
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "flutter_libpivxshield")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../rust pivx_shield_ffi "")

set(
  flutter_libpivxshield_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
