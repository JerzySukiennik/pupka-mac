#!/bin/zsh
# Downloads the official llama.cpp build for this Mac (pinned release) into Niepotrzebne/llama.
set -e
cd "$(dirname "$0")"
TAG="b12441"
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] && NAME="x64" || NAME="arm64"
mkdir -p llama-dl llama
curl -L --fail -s -S -o llama-dl/llama.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-macos-$NAME.tar.gz"
tar -xzf llama-dl/llama.tar.gz -C llama --strip-components=1
echo "llama.cpp $TAG ready"
