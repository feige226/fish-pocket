#!/usr/bin/env bash
# Copy WebRTC's echo canceller (AEC3) into native/aec3: the sources the voice call needs and
# every header they include, from the standalone WebRTC audio processing release and the abseil
# release it is built against, both checked against their sha256. The app compiles these files
# itself (the DshAec3 target in app/project.yml), so a clean checkout needs nothing downloaded.
#
# Run it again only to move to newer releases: change the versions and sha256 below, run it,
# build, and listen to a call on a real phone (CLAUDE.md, 语音通话). It rewrites native/aec3/webrtc
# and native/aec3/abseil and leaves the bridge (native/aec3/dsh_aec3.cc, include/) alone.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/native/aec3"

wap_version="2.1"
wap_sha256="ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
absl_version="20240722.0"
absl_sha256="f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3"

# AEC3 and what it calls, as webrtcaec3.js builds it (github.com/ennuicastr/webrtcaec3.js), plus
# the NEON halves of the resampler and the FFT for arm64.
sources="
api/audio/echo_canceller3_config.cc
common_audio/audio_util.cc
common_audio/resampler/push_sinc_resampler.cc
common_audio/resampler/sinc_resampler.cc
common_audio/resampler/sinc_resampler_neon.cc
common_audio/signal_processing/splitting_filter.c
common_audio/third_party/ooura/fft_size_128/ooura_fft.cc
common_audio/third_party/ooura/fft_size_128/ooura_fft_neon.cc
modules/audio_processing/aec3/adaptive_fir_filter.cc
modules/audio_processing/aec3/adaptive_fir_filter_erl.cc
modules/audio_processing/aec3/aec_state.cc
modules/audio_processing/aec3/aec3_common.cc
modules/audio_processing/aec3/aec3_fft.cc
modules/audio_processing/aec3/alignment_mixer.cc
modules/audio_processing/aec3/api_call_jitter_metrics.cc
modules/audio_processing/aec3/block_buffer.cc
modules/audio_processing/aec3/block_delay_buffer.cc
modules/audio_processing/aec3/block_framer.cc
modules/audio_processing/aec3/block_processor.cc
modules/audio_processing/aec3/block_processor_metrics.cc
modules/audio_processing/aec3/clockdrift_detector.cc
modules/audio_processing/aec3/coarse_filter_update_gain.cc
modules/audio_processing/aec3/comfort_noise_generator.cc
modules/audio_processing/aec3/config_selector.cc
modules/audio_processing/aec3/decimator.cc
modules/audio_processing/aec3/dominant_nearend_detector.cc
modules/audio_processing/aec3/downsampled_render_buffer.cc
modules/audio_processing/aec3/echo_audibility.cc
modules/audio_processing/aec3/echo_canceller3.cc
modules/audio_processing/aec3/echo_path_delay_estimator.cc
modules/audio_processing/aec3/echo_path_variability.cc
modules/audio_processing/aec3/echo_remover.cc
modules/audio_processing/aec3/echo_remover_metrics.cc
modules/audio_processing/aec3/erl_estimator.cc
modules/audio_processing/aec3/erle_estimator.cc
modules/audio_processing/aec3/fft_buffer.cc
modules/audio_processing/aec3/filter_analyzer.cc
modules/audio_processing/aec3/frame_blocker.cc
modules/audio_processing/aec3/fullband_erle_estimator.cc
modules/audio_processing/aec3/matched_filter.cc
modules/audio_processing/aec3/matched_filter_lag_aggregator.cc
modules/audio_processing/aec3/moving_average.cc
modules/audio_processing/aec3/multi_channel_content_detector.cc
modules/audio_processing/aec3/refined_filter_update_gain.cc
modules/audio_processing/aec3/render_buffer.cc
modules/audio_processing/aec3/render_delay_buffer.cc
modules/audio_processing/aec3/render_delay_controller.cc
modules/audio_processing/aec3/render_delay_controller_metrics.cc
modules/audio_processing/aec3/render_signal_analyzer.cc
modules/audio_processing/aec3/residual_echo_estimator.cc
modules/audio_processing/aec3/reverb_decay_estimator.cc
modules/audio_processing/aec3/reverb_frequency_response.cc
modules/audio_processing/aec3/reverb_model.cc
modules/audio_processing/aec3/reverb_model_estimator.cc
modules/audio_processing/aec3/signal_dependent_erle_estimator.cc
modules/audio_processing/aec3/spectrum_buffer.cc
modules/audio_processing/aec3/stationarity_estimator.cc
modules/audio_processing/aec3/subband_erle_estimator.cc
modules/audio_processing/aec3/subband_nearend_detector.cc
modules/audio_processing/aec3/subtractor.cc
modules/audio_processing/aec3/subtractor_output.cc
modules/audio_processing/aec3/subtractor_output_analyzer.cc
modules/audio_processing/aec3/suppression_filter.cc
modules/audio_processing/aec3/suppression_gain.cc
modules/audio_processing/aec3/transparent_mode.cc
modules/audio_processing/audio_buffer.cc
modules/audio_processing/high_pass_filter.cc
modules/audio_processing/logging/apm_data_dumper.cc
modules/audio_processing/splitting_filter.cc
modules/audio_processing/three_band_filter_bank.cc
modules/audio_processing/utility/cascaded_biquad_filter.cc
rtc_base/checks.cc
rtc_base/experiments/field_trial_parser.cc
rtc_base/memory/aligned_malloc.cc
rtc_base/platform_thread_types.cc
rtc_base/race_checker.cc
rtc_base/string_encode.cc
rtc_base/string_utils.cc
rtc_base/strings/string_builder.cc
rtc_base/system_time.cc
rtc_base/time_utils.cc
system_wrappers/source/field_trial.cc
system_wrappers/source/metrics.cc
"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() { # url sha256 file
  curl -sSfL -o "$work/$3" "$1"
  echo "$2  $work/$3" | shasum -a 256 -c - >/dev/null || { echo "aec3: $3 does not match its sha256" >&2; exit 1; }
}
fetch "https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-$wap_version.tar.xz" "$wap_sha256" wap.tar.xz
fetch "https://github.com/abseil/abseil-cpp/releases/download/$absl_version/abseil-cpp-$absl_version.tar.gz" "$absl_sha256" absl.tar.gz
tar -xf "$work/wap.tar.xz" -C "$work"
tar -xzf "$work/absl.tar.gz" -C "$work"
wap="$work/webrtc-audio-processing-$wap_version/webrtc"
absl="$work/abseil-cpp-$absl_version"

# Every file the sources include, found by the compiler with the target's own defines.
defines=(-DNDEBUG -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_IOS -DWEBRTC_ARCH_ARM64 -DWEBRTC_HAS_NEON
  -DWEBRTC_APM_DEBUG_DUMP=0 -DRTC_DISABLE_LOGGING -DWEBRTC_LIBRARY_IMPL)
files="$work/files"
: > "$files"
for source in $sources; do
  case "$source" in *.c) compiler=(clang) ;; *) compiler=(clang++ -std=c++17) ;; esac
  "${compiler[@]}" "${defines[@]}" -I"$wap" -I"$absl" -MM "$wap/$source" \
    | tr ' \\' '\n\n' | sed '/^$/d;/:$/d' >> "$files"
done

rm -rf "$out/webrtc" "$out/abseil"
copy() { # tree file
  local relative="${2#$1/}"
  mkdir -p "$(dirname "$3/$relative")"
  cp "$2" "$3/$relative"
}
sort -u "$files" | while read -r file; do
  case "$file" in
    "$wap"/*) copy "$wap" "$file" "$out/webrtc" ;;
    "$absl"/*) copy "$absl" "$file" "$out/abseil" ;;
    /*) ;; # the SDK's own headers
    *) echo "aec3: unexpected dependency $file" >&2; exit 1 ;;
  esac
done
cp "$wap/LICENSE" "$wap/PATENTS" "$out/webrtc/"
cp "$absl/LICENSE" "$out/abseil/"
echo "aec3: webrtc-audio-processing $wap_version and abseil $absl_version in native/aec3 ($(find "$out/webrtc" "$out/abseil" -type f | wc -l | tr -d ' ') files)"
