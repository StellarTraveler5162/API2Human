#!/usr/bin/env bash
# 将 SPM 可执行文件打包成 .app（TCC 权限弹窗需要 Info.plist + 稳定的 Bundle ID）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/API2Human"

APP="build/API2Human.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/API2Human"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# sherpa-onnx + onnxruntime 动态库（可执行文件的 rpath 指向 @executable_path/../Frameworks）
cp Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib Vendor/sherpa-onnx/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"

# 语音识别模型（只拷推理需要的文件；APFS 上用 clone，几乎不占时间和空间）
MODEL="sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05"
if [[ -d "Models/$MODEL" ]]; then
  mkdir -p "$APP/Contents/Resources/Models/$MODEL"
  for f in encoder.int8.onnx decoder.onnx joiner.int8.onnx tokens.txt bpe.vocab; do
    cp -c "Models/$MODEL/$f" "$APP/Contents/Resources/Models/$MODEL/" 2>/dev/null \
      || cp "Models/$MODEL/$f" "$APP/Contents/Resources/Models/$MODEL/"
  done
else
  echo "⚠️  没找到 Models/$MODEL，语音识别不可用。运行 scripts/fetch-models.sh 下载" >&2
fi

# 签名：优先用本机的自签名证书"API2Human Local Signing"——身份固定，重新打包后系统权限（屏幕录制等）不会失效；
# 没有这个证书时退回 ad-hoc（每次打包系统都会当成新 App，需要重新授权）。正式分发换成 Developer ID + 公证。
SIGN_ID="${A2H_SIGN_ID:-$(security find-identity -p codesigning 2>/dev/null | awk '/"API2Human Local Signing"/ {print $2; exit}')}"
if [[ -n "$SIGN_ID" ]]; then
  echo "签名身份：API2Human Local Signing ($SIGN_ID)"
else
  SIGN_ID="-"
  echo "⚠️  没找到 API2Human Local Signing 证书，使用 ad-hoc 签名"
fi
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$SIGN_ID" --identifier com.api2human.app "$APP"
echo "✅ $APP"
echo "运行：open $APP"
