# Qwen ASR runtime subset

Source: https://github.com/soniqo/speech-swift at a57702e6f523fa36ac5532d2bdc5f35f701a052c (Apache-2.0; LICENSE included).
Only the Qwen3-ASR MLX encoder, quantized decoder, tokenizer and needed helpers are vendored. Imports are flattened. Alignment, network loading, other models and server code are excluded. YouRec supplies 16 kHz mono PCM, owns cancellable verified downloads and uses an offline-only loader with bounded GPU cache. MLX Swift is pinned to 0.31.4 (MIT).

Weights are NOT bundled. The pinned Apache-2.0 Qwen3-ASR-0.6B 4-bit conversion is downloaded only on request. No audio or transcript is sent to a service.
