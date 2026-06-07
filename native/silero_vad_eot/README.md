# silero vad eot

Local end-of-turn detector for Telnyx phone audio.

Build:

```sh
make -C native/silero_vad_eot
```

By default the build links against Homebrew's ONNX Runtime:

```sh
brew install onnxruntime
make -C native/silero_vad_eot USE_ONNXRUNTIME=1
```

The Elixir app calls the binary with one JSON line on stdin and expects one JSON
decision on stdout. The interface is intentionally small so the ONNX-backed
Silero scorer stays isolated from the Elixir call-session orchestration.

Runtime env:

```sh
NEGOTIATOR_TURN_DETECTION=silero_vad
SILERO_VAD_BIN=native/silero_vad_eot/silero_vad_eot
SILERO_VAD_MODEL=priv/models/silero_vad.onnx
```

When `SILERO_VAD_MODEL` points to a readable ONNX model and the binary is built
with ONNX Runtime, output uses `backend: "silero_onnx"` and `model_loaded: true`.
If you build with `USE_ONNXRUNTIME=0` or omit the model, the binary returns an
explicit `silero_model_not_configured_energy_fallback_*` reason.
