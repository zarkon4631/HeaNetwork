#!/usr/bin/env bash
# Builds the Android core library (libbox.aar) from the sing-box-extended
# sources pinned in tool/core.json and drops it into android/app/libs.
#
# Needs: Go, JDK 17, the Android NDK (ANDROID_NDK_HOME), jq.
#   tool/build_libbox.sh                      # arm64-v8a, armeabi-v7a, x86_64
#   tool/build_libbox.sh android/arm64        # one ABI, for a quick local build
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(jq -r .repo "$root/tool/core.json")"
tag="$(jq -r .tag "$root/tool/core.json")"
target="${1:-android/arm64,android/arm,android/amd64}"

src="$root/.cache/core-src"
if [ ! -d "$src/.git" ] || [ "$(git -C "$src" describe --tags 2>/dev/null || true)" != "$tag" ]; then
  rm -rf "$src"
  git clone --depth 1 --branch "$tag" "https://github.com/$repo" "$src"
fi

# The gomobile fork the core is developed against.
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.13
export PATH="$PATH:$(go env GOPATH)/bin"

# The core's own tag set for Android, minus `with_naive_outbound`: that one
# pulls in a prebuilt Chromium network stack this client has no use for.
tags="with_gvisor,with_quic,with_wireguard,with_masque,with_mtproxy,with_trusttunnel"
tags+=",with_call,with_sudoku,with_utls,with_clash_api,with_usbip,with_openvpn"
tags+=",with_openconnect,badlinkname,tfogo_checklinkname0,with_tailscale"
tags+=",ts_omit_logtail,ts_omit_ssh,ts_omit_drive,ts_omit_taildrop,ts_omit_webclient"
tags+=",ts_omit_doctor,ts_omit_capture,ts_omit_kube,ts_omit_aws,ts_omit_synology"
tags+=",ts_omit_bird"

ldflags="-X github.com/sagernet/sing-box/constant.Version=${tag#v}"
ldflags+=" -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0"
ldflags+=" -s -w -buildid="

cd "$src"
gomobile bind -v \
  -o libbox.aar \
  -target "$target" \
  -androidapi 24 \
  -javapkg=io.nekohasekai \
  -libname=box \
  -trimpath -buildvcs=false \
  -ldflags "$ldflags" \
  -tags "$tags" \
  ./experimental/libbox

mkdir -p "$root/android/app/libs"
cp libbox.aar "$root/android/app/libs/libbox.aar"
ls -l "$root/android/app/libs/libbox.aar"
