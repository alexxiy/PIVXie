// Camera capture for the desktop QR scanner. A thread keeps the newest
// frame from the first V4L2 camera that delivers one; the Dart side polls
// it as JPEG.
//
// OpenCV is linked statically (see CMakeLists.txt), so no exception or
// symbol of it leaves this library: every entry point catches everything.
//
// The entry points run on Flutter's UI thread, so none of them waits for
// the camera: stopping only tells the capture thread to quit, and it
// closes the camera when its current read returns. A camera that hangs in
// its driver can't freeze the app.

#include "camera_linux.h"

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/videoio.hpp>

namespace {

using Clock = std::chrono::steady_clock;

// How often a frame is decoded for the scanner. Frames in between are only
// dequeued, so the one handed out is never older than this.
constexpr auto kFrameInterval = std::chrono::milliseconds(200);
// How long a new start keeps trying while an earlier capture thread still
// holds the camera.
constexpr auto kOpenRetryFor = std::chrono::seconds(3);
constexpr auto kOpenRetryEvery = std::chrono::milliseconds(100);
constexpr int kMaxDevices = 10;

struct State {
  // Bumped by every start and stop; a capture thread runs while it still
  // matches the value it started with.
  std::atomic<unsigned> session{0};
  std::mutex frameMutex;
  cv::Mat latestFrame;
};

// Never destroyed: a capture thread may outlive the app's static
// destructors at exit.
State& state() {
  static State* s = new State;
  return *s;
}

// The first camera that opens and delivers a frame. Not just /dev/video0:
// a webcam's metadata node or an IR camera can come first.
bool openCamera(cv::VideoCapture& cap, unsigned session) {
  for (int i = 0; i < kMaxDevices && state().session == session; i++) {
    const std::string device = "/dev/video" + std::to_string(i);
    if (access(device.c_str(), R_OK) != 0) continue;
    if (!cap.open(i, cv::CAP_V4L2)) continue;
    if (cap.grab()) return true;
    cap.release();
  }
  return false;
}

void captureLoop(unsigned session) {
  State& s = state();
  auto current = [&] { return s.session == session; };
  try {
    cv::VideoCapture cap;
    // The thread of an earlier session may not have let go of it yet.
    const auto giveUp = Clock::now() + kOpenRetryFor;
    while (!openCamera(cap, session)) {
      if (!current() || Clock::now() > giveUp) return;
      std::this_thread::sleep_for(kOpenRetryEvery);
    }
    cv::Mat frame;
    auto lastDecoded = Clock::now() - kFrameInterval;
    // grab() dequeues without decoding; draining the queue this way keeps
    // the decoded frame current instead of seconds behind.
    do {
      if (Clock::now() - lastDecoded < kFrameInterval) continue;
      lastDecoded = Clock::now();
      if (!cap.retrieve(frame) || frame.empty()) continue;
      cv::Mat copy = frame.clone();
      std::lock_guard<std::mutex> lock(s.frameMutex);
      if (current()) s.latestFrame = std::move(copy);
    } while (current() && cap.grab());
  } catch (...) {
    // The camera went away or OpenCV failed: the scanner just gets no
    // more frames.
  }
}

// Ends the current session: its thread quits on its own, and its frames
// are no longer handed out.
unsigned newSession() {
  State& s = state();
  std::lock_guard<std::mutex> lock(s.frameMutex);
  s.latestFrame.release();
  return ++s.session;
}

}  // namespace

extern "C" {

CAMERA_LINUX_EXPORT void stopVideoCapture() {
  try {
    newSession();
  } catch (...) {
  }
}

CAMERA_LINUX_EXPORT void startVideoCaptureInThread() {
  try {
    std::thread(captureLoop, newSession()).detach();
  } catch (...) {
  }
}

CAMERA_LINUX_EXPORT uint8_t* getLatestFrameBytes(int* length) {
  if (!length) return nullptr;
  *length = 0;
  try {
    State& s = state();
    cv::Mat frame;
    {
      std::lock_guard<std::mutex> lock(s.frameMutex);
      if (s.latestFrame.empty()) return nullptr;
      // Each frame is handed out once.
      frame = std::move(s.latestFrame);
      s.latestFrame = cv::Mat();
    }
    std::vector<uint8_t> jpeg;
    if (!cv::imencode(".jpg", frame, jpeg) || jpeg.empty()) return nullptr;
    // malloc, not new[]: the Dart side frees it with free().
    auto* data = static_cast<uint8_t*>(std::malloc(jpeg.size()));
    if (!data) return nullptr;
    std::memcpy(data, jpeg.data(), jpeg.size());
    *length = static_cast<int>(jpeg.size());
    return data;
  } catch (...) {
    return nullptr;
  }
}

}  // extern "C"
