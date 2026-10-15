#!/bin/bash
# A small static OpenCV for the camera_linux plugin (desktop QR scanner):
# core, imgproc, imgcodecs and videoio, V4L2 capture and JPEG only. The
# plugin links it into its own library, so the app bundle runs without
# OpenCV installed. Installs to build/opencv/install; the Linux CMake file
# looks for it there.
#
# USE_SYSTEM_OPENCV=1 skips it: the plugin then links the system OpenCV,
# which users must have installed.

set -e

if [ "${USE_SYSTEM_OPENCV:-0}" = "1" ]; then
  echo "USE_SYSTEM_OPENCV is set; skipping the OpenCV build (using the system one)"
  exit 0
fi

OPENCV_TAG=5.0.0
LINUX_DIRECTORY=$(pwd)
OPENCV_DIR="$LINUX_DIRECTORY/build/opencv"
PREFIX="$OPENCV_DIR/install"
# Changing this script (version, options) rebuilds.
STAMP="$PREFIX/.built-$OPENCV_TAG-$(sha256sum "$0" | cut -c1-16)"

if [ -f "$STAMP" ]; then
  echo "OpenCV $OPENCV_TAG is already built"
  exit 0
fi

for tool in git cmake; do
  if ! [ -x "$(command -v $tool)" ]; then
    echo "Error: $tool is not installed." >&2
    exit 1
  fi
done

mkdir -p "$OPENCV_DIR"
cd "$OPENCV_DIR"
if [ -d src/.git ]; then
  git -C src fetch --depth 1 origin tag "$OPENCV_TAG"
  git -C src checkout -q "$OPENCV_TAG"
else
  rm -rf src
  git clone --depth 1 --branch "$OPENCV_TAG" https://github.com/opencv/opencv.git src
fi

GENERATOR="Unix Makefiles"
[ -x "$(command -v ninja)" ] && GENERATOR=Ninja

rm -rf build-static "$PREFIX"
# Everything not needed for grabbing V4L2 frames and encoding JPEG is off,
# including all downloads (IPP, ADE, the Unicode font for drawing text).
# JPEG SIMD needs NASM; without it the build would differ between hosts,
# and 5 frames a second don't need it.
cmake -S src -B build-static -G "$GENERATOR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DOPENCV_CONFIG_INSTALL_PATH=lib/cmake/opencv \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_LIST=core,imgproc,imgcodecs,videoio \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_DOCS=OFF -DBUILD_JAVA=OFF \
  -DBUILD_opencv_python3=OFF -DBUILD_opencv_js=OFF \
  -DOPENCV_GENERATE_PKGCONFIG=OFF \
  -DWITH_V4L=ON -DWITH_LIBV4L=OFF \
  -DWITH_JPEG=ON -DBUILD_JPEG=ON -DENABLE_LIBJPEG_TURBO_SIMD=OFF \
  -DWITH_ZLIB=ON -DBUILD_ZLIB=ON \
  -DWITH_PNG=OFF -DWITH_SPNG=OFF -DWITH_TIFF=OFF -DWITH_WEBP=OFF \
  -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_OPENEXR=OFF \
  -DWITH_AVIF=OFF -DWITH_JPEGXL=OFF -DWITH_IMGCODEC_HDR=OFF \
  -DWITH_IMGCODEC_SUNRASTER=OFF -DWITH_IMGCODEC_PXM=OFF \
  -DWITH_IMGCODEC_PFM=OFF -DWITH_IMGCODEC_GIF=OFF \
  -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_1394=OFF \
  -DWITH_GPHOTO2=OFF -DWITH_ARAVIS=OFF -DWITH_OBSENSOR=OFF \
  -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_OPENGL=OFF -DWITH_VTK=OFF \
  -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF -DWITH_VA=OFF \
  -DWITH_VA_INTEL=OFF -DWITH_CUDA=OFF -DWITH_EIGEN=OFF -DWITH_LAPACK=OFF \
  -DWITH_OPENMP=OFF -DWITH_TBB=OFF -DWITH_PROTOBUF=OFF -DWITH_ADE=OFF \
  -DWITH_QUIRC=OFF -DWITH_FLATBUFFERS=OFF -DWITH_KLEIDICV=OFF \
  -DWITH_OPENVX=OFF -DWITH_HALIDE=OFF -DWITH_CAROTENE=OFF \
  -DWITH_UNIFONT=OFF \
  -DCV_TRACE=OFF
cmake --build build-static -j"$(nproc)"
cmake --install build-static
touch "$STAMP"
echo "OpenCV $OPENCV_TAG installed to $PREFIX"
