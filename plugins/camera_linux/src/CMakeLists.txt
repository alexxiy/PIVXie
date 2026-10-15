cmake_minimum_required(VERSION 3.13)
project(camera_linux_library VERSION 0.0.8 LANGUAGES CXX)

# OpenCV comes from CAMERA_LINUX_OPENCV_DIR when the app sets it: a small
# static build (scripts/linux/build_opencv.sh in PIVXie) that ends up
# inside this library, so the app bundle needs no OpenCV installed.
# Otherwise the system OpenCV is linked, and users need it installed.
set(CAMERA_LINUX_OPENCV_MODULES core imgproc imgcodecs videoio)
# A cached path from an earlier configure would win over the choice below.
unset(OpenCV_DIR CACHE)
if(CAMERA_LINUX_OPENCV_DIR)
  find_package(OpenCV REQUIRED COMPONENTS ${CAMERA_LINUX_OPENCV_MODULES}
    PATHS "${CAMERA_LINUX_OPENCV_DIR}" NO_DEFAULT_PATH)
else()
  find_package(OpenCV REQUIRED COMPONENTS ${CAMERA_LINUX_OPENCV_MODULES})
endif()

add_library(camera_linux SHARED camera_linux.cpp)
target_compile_features(camera_linux PRIVATE cxx_std_17)
target_include_directories(camera_linux PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(camera_linux PRIVATE ${OpenCV_LIBS})
set_target_properties(camera_linux PROPERTIES
  PUBLIC_HEADER camera_linux.h
  OUTPUT_NAME "camera_linux"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)
# Keep a static OpenCV's symbols private and drop what the library doesn't
# use; release builds also lose the symbol table.
target_link_options(camera_linux PRIVATE
  "LINKER:--exclude-libs,ALL"
  "LINKER:--gc-sections"
  "LINKER:--as-needed"
  "$<$<CONFIG:Release>:-s>"
)
target_compile_definitions(camera_linux PUBLIC DART_SHARED_LIB)
