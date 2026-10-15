#include <stdint.h>

// The library hides everything else (OpenCV is linked in statically).
#define CAMERA_LINUX_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

// Opens the first camera that delivers frames and keeps capturing in a
// background thread. Ends an earlier capture first. Doesn't wait for the
// camera.
CAMERA_LINUX_EXPORT void startVideoCaptureInThread(void);

// Stops capturing without waiting: the background thread closes the
// camera once its current read returns.
CAMERA_LINUX_EXPORT void stopVideoCapture(void);

// The newest frame as JPEG (its size in *length), or NULL when no new frame
// arrived since the last call. The caller frees it with free().
CAMERA_LINUX_EXPORT uint8_t* getLatestFrameBytes(int* length);

#ifdef __cplusplus
}
#endif
