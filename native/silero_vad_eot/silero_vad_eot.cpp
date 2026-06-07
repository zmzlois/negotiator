#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef USE_ONNXRUNTIME
#include <onnxruntime_cxx_api.h>
#endif

namespace {

struct Request {
  std::vector<unsigned char> pcm16le;
  int sample_rate = 8000;
  int frame_ms = 20;
  int min_speech_ms = 180;
  int end_silence_ms = 650;
  double energy_threshold = 0.012;
  double speech_threshold = 0.5;
  std::string model_path;
  bool stream = false;
  bool reset = false;
};

struct Decision {
  std::string backend = "energy_fallback";
  bool model_loaded = false;
  double speech_probability = 0.0;
  int speech_ms = 0;
  int trailing_silence_ms = 0;
  double end_probability = 0.0;
  bool should_wait = true;
  bool should_reply = false;
  std::string reason;
};

std::string trim(const std::string &value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) {
    return "";
  }

  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::string json_string(const std::string &body, const std::string &key,
                        const std::string &fallback = "") {
  const std::string marker = "\"" + key + "\"";
  auto pos = body.find(marker);
  if (pos == std::string::npos) {
    return fallback;
  }

  pos = body.find(':', pos + marker.size());
  if (pos == std::string::npos) {
    return fallback;
  }

  pos = body.find('"', pos + 1);
  if (pos == std::string::npos) {
    return fallback;
  }

  std::string out;
  bool escaped = false;

  for (std::size_t i = pos + 1; i < body.size(); ++i) {
    const char c = body[i];

    if (escaped) {
      out.push_back(c);
      escaped = false;
      continue;
    }

    if (c == '\\') {
      escaped = true;
      continue;
    }

    if (c == '"') {
      return out;
    }

    out.push_back(c);
  }

  return fallback;
}

int json_int(const std::string &body, const std::string &key, int fallback) {
  const std::string marker = "\"" + key + "\"";
  auto pos = body.find(marker);
  if (pos == std::string::npos) {
    return fallback;
  }

  pos = body.find(':', pos + marker.size());
  if (pos == std::string::npos) {
    return fallback;
  }

  const auto start = body.find_first_of("-0123456789", pos + 1);
  if (start == std::string::npos) {
    return fallback;
  }

  const auto end = body.find_first_not_of("-0123456789", start);
  return std::stoi(body.substr(start, end - start));
}

double json_double(const std::string &body, const std::string &key,
                   double fallback) {
  const std::string marker = "\"" + key + "\"";
  auto pos = body.find(marker);
  if (pos == std::string::npos) {
    return fallback;
  }

  pos = body.find(':', pos + marker.size());
  if (pos == std::string::npos) {
    return fallback;
  }

  const auto start = body.find_first_of("-0123456789.", pos + 1);
  if (start == std::string::npos) {
    return fallback;
  }

  const auto end = body.find_first_not_of("-0123456789.eE+", start);
  return std::stod(body.substr(start, end - start));
}

bool json_bool(const std::string &body, const std::string &key, bool fallback) {
  const std::string marker = "\"" + key + "\"";
  auto pos = body.find(marker);
  if (pos == std::string::npos) {
    return fallback;
  }

  pos = body.find(':', pos + marker.size());
  if (pos == std::string::npos) {
    return fallback;
  }

  const auto start = body.find_first_not_of(" \t\r\n", pos + 1);
  if (start == std::string::npos) {
    return fallback;
  }

  if (body.compare(start, 4, "true") == 0) {
    return true;
  }

  if (body.compare(start, 5, "false") == 0) {
    return false;
  }

  return fallback;
}

std::vector<unsigned char> base64_decode(const std::string &encoded) {
  static const std::string chars =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  std::vector<int> table(256, -1);
  for (int i = 0; i < static_cast<int>(chars.size()); ++i) {
    table[static_cast<unsigned char>(chars[i])] = i;
  }

  std::vector<unsigned char> out;
  int value = 0;
  int bits = -8;

  for (unsigned char c : encoded) {
    if (c == '=') {
      break;
    }

    if (table[c] == -1) {
      continue;
    }

    value = (value << 6) + table[c];
    bits += 6;

    if (bits >= 0) {
      out.push_back(static_cast<unsigned char>((value >> bits) & 0xFF));
      bits -= 8;
    }
  }

  return out;
}

Request parse_request(const std::string &line) {
  Request request;
  request.sample_rate = json_int(line, "sample_rate", request.sample_rate);
  request.frame_ms = json_int(line, "frame_ms", request.frame_ms);
  request.min_speech_ms = json_int(line, "min_speech_ms", request.min_speech_ms);
  request.end_silence_ms =
      json_int(line, "end_silence_ms", request.end_silence_ms);
  request.energy_threshold =
      json_double(line, "energy_threshold", request.energy_threshold);
  request.speech_threshold =
      json_double(line, "speech_threshold", request.speech_threshold);
  request.stream = json_bool(line, "stream", request.stream);
  request.reset = json_bool(line, "reset", request.reset);
  request.model_path = json_string(line, "model_path", "");

  const auto bytes = json_string(line, "bytes_b64", "");
  request.pcm16le = base64_decode(bytes);

  if (request.sample_rate <= 0) {
    throw std::runtime_error("sample_rate must be positive");
  }

  if (request.frame_ms <= 0) {
    throw std::runtime_error("frame_ms must be positive");
  }

  if (request.pcm16le.size() < 2) {
    throw std::runtime_error("bytes_b64 did not contain pcm16le audio");
  }

  return request;
}

double clamp(double value, double lower = 0.0, double upper = 1.0) {
  return std::max(lower, std::min(upper, value));
}

int16_t pcm16_sample(const std::vector<unsigned char> &bytes,
                     std::size_t sample_index) {
  const auto i = sample_index * 2;
  const auto lo = static_cast<uint16_t>(bytes[i]);
  const auto hi = static_cast<uint16_t>(bytes[i + 1]);
  return static_cast<int16_t>(lo | (hi << 8));
}

double frame_rms(const std::vector<unsigned char> &bytes, std::size_t start,
                 std::size_t count) {
  double sum = 0.0;

  for (std::size_t i = 0; i < count; ++i) {
    const double sample = static_cast<double>(pcm16_sample(bytes, start + i));
    sum += sample * sample;
  }

  return std::sqrt(sum / static_cast<double>(count)) / 32768.0;
}

bool readable_file(const std::string &path) {
  if (path.empty()) {
    return false;
  }

  std::ifstream file(path);
  return file.good();
}

void update_endpoint_decision(Decision &decision, double probability,
                              double threshold, int chunk_ms) {
  const bool speech = probability >= threshold;
  decision.speech_probability = std::max(decision.speech_probability, probability);

  if (speech) {
    decision.speech_ms += chunk_ms;
    decision.trailing_silence_ms = 0;
  } else if (decision.speech_ms > 0) {
    decision.trailing_silence_ms += chunk_ms;
  }
}

void finish_endpoint_decision(Decision &decision, const Request &request,
                              const std::string &prefix) {
  if (decision.speech_ms < request.min_speech_ms) {
    decision.end_probability = clamp(decision.speech_probability * 0.25);
    decision.should_wait = true;
    decision.should_reply = false;
    decision.reason = prefix + "_no_speech";
    return;
  }

  decision.end_probability =
      clamp(static_cast<double>(decision.trailing_silence_ms) /
            static_cast<double>(std::max(1, request.end_silence_ms)));
  decision.should_reply = decision.trailing_silence_ms >= request.end_silence_ms;
  decision.should_wait = !decision.should_reply;
  decision.reason = decision.should_reply ? prefix + "_end" : prefix + "_wait";
}

#ifdef USE_ONNXRUNTIME
Decision score_silero_endpoint(const Request &request) {
  if (!readable_file(request.model_path)) {
    throw std::runtime_error("silero model is not readable: " + request.model_path);
  }

  const int chunk_samples = request.sample_rate == 16000 ? 512 : 256;
  const int chunk_ms = chunk_samples * 1000 / request.sample_rate;
  const auto sample_count = request.pcm16le.size() / 2;

  Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "silero_vad_eot");
  Ort::SessionOptions options;
  options.SetIntraOpNumThreads(1);
  Ort::Session session(env, request.model_path.c_str(), options);
  Ort::MemoryInfo memory_info =
      Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  const char *input_names[] = {"input", "state", "sr"};
  const char *output_names[] = {"output", "stateN"};

  std::vector<float> state(2 * 1 * 128, 0.0f);
  std::array<int64_t, 3> state_shape{2, 1, 128};
  std::array<int64_t, 1> sr_shape{1};
  int64_t sr_value = request.sample_rate;
  Decision decision;
  decision.backend = "silero_onnx";
  decision.model_loaded = true;

  for (std::size_t start = 0; start < sample_count; start += chunk_samples) {
    std::vector<float> chunk(chunk_samples, 0.0f);
    const auto available = std::min<std::size_t>(chunk_samples, sample_count - start);

    for (std::size_t i = 0; i < available; ++i) {
      chunk[i] = static_cast<float>(pcm16_sample(request.pcm16le, start + i)) / 32768.0f;
    }

    std::array<int64_t, 2> input_shape{1, chunk_samples};

    std::vector<Ort::Value> inputs;
    inputs.emplace_back(Ort::Value::CreateTensor<float>(
        memory_info, chunk.data(), chunk.size(), input_shape.data(),
        input_shape.size()));
    inputs.emplace_back(Ort::Value::CreateTensor<float>(
        memory_info, state.data(), state.size(), state_shape.data(),
        state_shape.size()));
    inputs.emplace_back(Ort::Value::CreateTensor<int64_t>(
        memory_info, &sr_value, 1, sr_shape.data(), sr_shape.size()));

    auto outputs = session.Run(Ort::RunOptions{nullptr}, input_names, inputs.data(),
                               inputs.size(), output_names, 2);

    const float probability = outputs[0].GetTensorMutableData<float>()[0];
    auto next_state_info = outputs[1].GetTensorTypeAndShapeInfo();
    const auto next_state_count = next_state_info.GetElementCount();
    const float *next_state = outputs[1].GetTensorData<float>();
    state.assign(next_state, next_state + next_state_count);

    update_endpoint_decision(decision, probability, request.speech_threshold,
                             chunk_ms);
  }

  finish_endpoint_decision(decision, request, "silero_onnx");
  return decision;
}
#endif

Decision score_energy_endpoint(const Request &request) {
  Decision decision;
  const auto sample_count = request.pcm16le.size() / 2;
  const auto frame_samples =
      std::max<std::size_t>(1, request.sample_rate * request.frame_ms / 1000);
  const auto frame_ms = request.frame_ms;

  double peak_probability = 0.0;

  for (std::size_t start = 0; start + frame_samples <= sample_count;
       start += frame_samples) {
    const auto rms = frame_rms(request.pcm16le, start, frame_samples);
    const auto probability = clamp(rms / std::max(0.0001, request.energy_threshold));
    peak_probability = std::max(peak_probability, probability);
    update_endpoint_decision(decision, probability, 1.0, frame_ms);
  }

  decision.speech_probability = peak_probability;

  finish_endpoint_decision(decision, request,
                           "silero_model_not_configured_energy_fallback");
  return decision;
}

Decision score_endpoint(const Request &request) {
#ifdef USE_ONNXRUNTIME
  if (readable_file(request.model_path)) {
    return score_silero_endpoint(request);
  }
#endif

  return score_energy_endpoint(request);
}

class StreamingEndpointScorer {
public:
  Decision score(const Request &request) {
    configure(request);

    if (request.reset) {
      reset();
    }

#ifdef USE_ONNXRUNTIME
    if (readable_file(request.model_path)) {
      return score_silero_stream(request);
    }
#endif

    return score_energy_stream(request);
  }

private:
  Decision decision_;
  std::string model_path_;
  int sample_rate_ = 0;

#ifdef USE_ONNXRUNTIME
  Ort::Env env_{ORT_LOGGING_LEVEL_WARNING, "silero_vad_eot_stream"};
  std::unique_ptr<Ort::Session> session_;
  std::vector<float> state_ = std::vector<float>(2 * 1 * 128, 0.0f);
#endif

  void configure(const Request &request) {
    if (sample_rate_ != request.sample_rate || model_path_ != request.model_path) {
      sample_rate_ = request.sample_rate;
      model_path_ = request.model_path;
      reset();
    }
  }

  void reset() {
    decision_ = Decision{};

#ifdef USE_ONNXRUNTIME
    session_.reset();
    std::fill(state_.begin(), state_.end(), 0.0f);
#endif
  }

#ifdef USE_ONNXRUNTIME
  Ort::Session &session(const Request &request) {
    if (!session_) {
      Ort::SessionOptions options;
      options.SetIntraOpNumThreads(1);
      session_ =
          std::make_unique<Ort::Session>(env_, request.model_path.c_str(), options);
    }

    return *session_;
  }

  Decision score_silero_stream(const Request &request) {
    const int chunk_samples = request.sample_rate == 16000 ? 512 : 256;
    const int chunk_ms = chunk_samples * 1000 / request.sample_rate;
    const auto sample_count = request.pcm16le.size() / 2;
    auto &onnx_session = session(request);
    Ort::MemoryInfo memory_info =
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

    const char *input_names[] = {"input", "state", "sr"};
    const char *output_names[] = {"output", "stateN"};
    std::array<int64_t, 3> state_shape{2, 1, 128};
    std::array<int64_t, 1> sr_shape{1};
    int64_t sr_value = request.sample_rate;

    decision_.backend = "silero_onnx";
    decision_.model_loaded = true;

    for (std::size_t start = 0; start < sample_count; start += chunk_samples) {
      std::vector<float> chunk(chunk_samples, 0.0f);
      const auto available = std::min<std::size_t>(chunk_samples, sample_count - start);

      for (std::size_t i = 0; i < available; ++i) {
        chunk[i] = static_cast<float>(pcm16_sample(request.pcm16le, start + i)) /
                   32768.0f;
      }

      std::array<int64_t, 2> input_shape{1, chunk_samples};
      std::vector<Ort::Value> inputs;
      inputs.emplace_back(Ort::Value::CreateTensor<float>(
          memory_info, chunk.data(), chunk.size(), input_shape.data(),
          input_shape.size()));
      inputs.emplace_back(Ort::Value::CreateTensor<float>(
          memory_info, state_.data(), state_.size(), state_shape.data(),
          state_shape.size()));
      inputs.emplace_back(Ort::Value::CreateTensor<int64_t>(
          memory_info, &sr_value, 1, sr_shape.data(), sr_shape.size()));

      auto outputs = onnx_session.Run(Ort::RunOptions{nullptr}, input_names,
                                      inputs.data(), inputs.size(), output_names, 2);

      const float probability = outputs[0].GetTensorMutableData<float>()[0];
      auto next_state_info = outputs[1].GetTensorTypeAndShapeInfo();
      const auto next_state_count = next_state_info.GetElementCount();
      const float *next_state = outputs[1].GetTensorData<float>();
      state_.assign(next_state, next_state + next_state_count);

      update_endpoint_decision(decision_, probability, request.speech_threshold,
                               chunk_ms);
    }

    finish_endpoint_decision(decision_, request, "silero_onnx");

    if (decision_.should_reply) {
      Decision emitted = decision_;
      reset();
      return emitted;
    }

    return decision_;
  }
#endif

  Decision score_energy_stream(const Request &request) {
    const auto sample_count = request.pcm16le.size() / 2;
    const auto frame_samples =
        std::max<std::size_t>(1, request.sample_rate * request.frame_ms / 1000);
    const auto frame_ms = request.frame_ms;
    double peak_probability = decision_.speech_probability;

    for (std::size_t start = 0; start + frame_samples <= sample_count;
         start += frame_samples) {
      const auto rms = frame_rms(request.pcm16le, start, frame_samples);
      const auto probability = clamp(rms / std::max(0.0001, request.energy_threshold));
      peak_probability = std::max(peak_probability, probability);
      update_endpoint_decision(decision_, probability, 1.0, frame_ms);
    }

    decision_.speech_probability = peak_probability;
    finish_endpoint_decision(decision_, request,
                             "silero_model_not_configured_energy_fallback");

    if (decision_.should_reply) {
      Decision emitted = decision_;
      reset();
      return emitted;
    }

    return decision_;
  }
};

std::string to_json(const Decision &decision, const Request &request) {
  std::ostringstream out;
  out << std::fixed << std::setprecision(4);
  out << "{";
  out << "\"backend\":\"" << decision.backend << "\",";
  out << "\"model_loaded\":" << (decision.model_loaded ? "true" : "false") << ",";
  out << "\"model_path_configured\":"
      << (!request.model_path.empty() ? "true" : "false") << ",";
  out << "\"speech_probability\":" << decision.speech_probability << ",";
  out << "\"speech_ms\":" << decision.speech_ms << ",";
  out << "\"trailing_silence_ms\":" << decision.trailing_silence_ms << ",";
  out << "\"end_probability\":" << decision.end_probability << ",";
  out << "\"should_wait\":" << (decision.should_wait ? "true" : "false") << ",";
  out << "\"should_reply\":" << (decision.should_reply ? "true" : "false")
      << ",";
  out << "\"reason\":\"" << decision.reason << "\"";
  out << "}";
  return out.str();
}

std::string error_json(const std::string &message) {
  std::ostringstream out;
  out << "{\"error\":\"";
  for (const char c : message) {
    if (c == '"' || c == '\\') {
      out << '\\';
    }
    out << c;
  }
  out << "\"}";
  return out.str();
}

int run_line(const std::string &line, StreamingEndpointScorer &streaming_scorer) {
  try {
    const auto request = parse_request(line);
    const auto decision =
        request.stream ? streaming_scorer.score(request) : score_endpoint(request);
    std::cout << to_json(decision, request) << std::endl;
    return 0;
  } catch (const std::exception &error) {
    std::cout << error_json(error.what()) << std::endl;
    return 1;
  }
}

} // namespace

int main() {
  std::string line;
  int exit_code = 0;
  StreamingEndpointScorer streaming_scorer;

  while (std::getline(std::cin, line)) {
    line = trim(line);
    if (line.empty()) {
      continue;
    }

    exit_code = std::max(exit_code, run_line(line, streaming_scorer));
  }

  return exit_code;
}
