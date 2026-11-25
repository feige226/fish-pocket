#include "dsh_aec3.h"

#include <memory>
#include <optional>

#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include "modules/audio_processing/audio_buffer.h"

struct DshAec3 {
  int core_rate;
  int render_rate;
  int capture_rate;
  std::unique_ptr<webrtc::EchoCanceller3> canceller;
  // Each resamples from the rate it is given to the canceller's; the capture one back again.
  std::unique_ptr<webrtc::AudioBuffer> render;
  std::unique_ptr<webrtc::AudioBuffer> capture;
};

DshAec3 *dsh_aec3_create(int core_rate_hz, int render_rate_hz, int capture_rate_hz) {
  if (core_rate_hz != 16000 && core_rate_hz != 32000 && core_rate_hz != 48000) return nullptr;
  if (render_rate_hz <= 0 || render_rate_hz % 100 || capture_rate_hz <= 0 || capture_rate_hz % 100) return nullptr;
  auto *aec = new DshAec3();
  aec->core_rate = core_rate_hz;
  aec->render_rate = render_rate_hz;
  aec->capture_rate = capture_rate_hz;
  webrtc::EchoCanceller3Config config;
  // When the echo path changes under it (the phone picked up or put down, a hand over the
  // speaker), the echo its filter no longer matches looks like someone talking, and what it then
  // lets through recognition hears as her words. So it decides that the user is the louder one
  // against the echo it is sure to leave, not against its best guess, which is far too low right
  // then; and when it does decide so, it lets no more of the low band through than otherwise.
  config.suppressor.dominant_nearend_detection.use_unbounded_echo_spectrum = false;
  config.suppressor.nearend_tuning = config.suppressor.normal_tuning;
  aec->canceller = std::make_unique<webrtc::EchoCanceller3>(config, std::nullopt, core_rate_hz, 1, 1);
  // The processed microphone is what recognition hears.
  aec->canceller->SetCaptureOutputUsage(true);
  aec->render = std::make_unique<webrtc::AudioBuffer>(render_rate_hz, 1, core_rate_hz, 1, core_rate_hz, 1);
  aec->capture = std::make_unique<webrtc::AudioBuffer>(capture_rate_hz, 1, core_rate_hz, 1, capture_rate_hz, 1);
  return aec;
}

void dsh_aec3_destroy(DshAec3 *aec) { delete aec; }

void dsh_aec3_analyze_render(DshAec3 *aec, const float *frame) {
  const float *channels[1] = {frame};
  aec->render->CopyFrom(channels, webrtc::StreamConfig(aec->render_rate, 1));
  // Above 16 kHz the canceller works on bands; at 16 kHz there is one.
  if (aec->core_rate > 16000) aec->render->SplitIntoFrequencyBands();
  aec->canceller->AnalyzeRender(aec->render.get());
}

void dsh_aec3_process_capture(DshAec3 *aec, float *frame) {
  const webrtc::StreamConfig config(aec->capture_rate, 1);
  const float *input[1] = {frame};
  aec->capture->CopyFrom(input, config);
  if (aec->core_rate > 16000) aec->capture->SplitIntoFrequencyBands();
  aec->canceller->AnalyzeCapture(aec->capture.get());
  aec->canceller->ProcessCapture(aec->capture.get(), false);
  if (aec->core_rate > 16000) aec->capture->MergeFrequencyBands();
  float *output[1] = {frame};
  aec->capture->CopyTo(config, output);
}

DshAec3Metrics dsh_aec3_metrics(const DshAec3 *aec) {
  const auto metrics = aec->canceller->GetMetrics();
  return {metrics.echo_return_loss, metrics.echo_return_loss_enhancement, metrics.delay_ms};
}
