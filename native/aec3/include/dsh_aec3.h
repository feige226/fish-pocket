// WebRTC's echo canceller (AEC3) for the voice call, behind plain C for Swift.
//
// Mono, 10 ms at a time. The canceller works at its own rate; what the speaker played (the far
// end) and the microphone come in at theirs and are resampled inside, and the cleaned microphone
// goes out at the microphone's rate. Each 10 ms of the far end goes to dsh_aec3_analyze_render
// before the microphone captured at the same moment goes to dsh_aec3_process_capture, which takes
// her voice out of it in place. Samples are floats in -1…1. Not thread-safe: one caller at a time.
#ifndef DSH_AEC3_H
#define DSH_AEC3_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DshAec3 DshAec3;

/// `core_rate_hz` is 16000, 32000 or 48000; the other two are any multiple of 100. NULL otherwise.
DshAec3 *dsh_aec3_create(int core_rate_hz, int render_rate_hz, int capture_rate_hz);
void dsh_aec3_destroy(DshAec3 *aec);
/// render_rate_hz / 100 samples.
void dsh_aec3_analyze_render(DshAec3 *aec, const float *frame);
/// capture_rate_hz / 100 samples, cleaned in place.
void dsh_aec3_process_capture(DshAec3 *aec, float *frame);

/// What the canceller reports of itself: how much the echo path loses on its own, how much the
/// canceller takes out on top (both in dB), and the delay it found between speaker and microphone.
typedef struct {
  double echo_return_loss;
  double echo_return_loss_enhancement;
  int delay_ms;
} DshAec3Metrics;
DshAec3Metrics dsh_aec3_metrics(const DshAec3 *aec);

#ifdef __cplusplus
}
#endif

#endif
