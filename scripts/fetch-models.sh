#!/usr/bin/env bash
# 下载 sherpa-onnx 运行库和流式中英识别模型（Vendor/ 和 Models/ 不进 git）
set -euo pipefail
cd "$(dirname "$0")/.."

V=v2.0.1
MODEL="sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
GH=https://github.com/k2-fsa/sherpa-onnx/releases/download

if [[ ! -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ]]; then
  mkdir -p Vendor/sherpa-onnx/lib Vendor/sherpa-onnx/include/sherpa-onnx/c-api
  tmp=$(mktemp -d)
  curl -fL "$GH/$V/sherpa-onnx-$V-osx-arm64-shared-lib.tar.bz2" | tar xj -C "$tmp"
  cp "$tmp"/*/lib/libsherpa-onnx-c-api.dylib "$tmp"/*/lib/libonnxruntime.dylib Vendor/sherpa-onnx/lib/
  curl -fL -o Vendor/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$V/sherpa-onnx/c-api/c-api.h"
  rm -rf "$tmp"
fi

if [[ ! -d "Models/$MODEL" ]]; then
  mkdir -p Models
  curl -fL "$GH/asr-models/$MODEL.tar.bz2" | tar xj -C Models
fi
echo "✅ sherpa-onnx $V + $MODEL"
