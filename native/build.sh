#!/usr/bin/env bash
# One command builds the native accelerator. It fetches the pinned godot-cpp into
# native/deps/ (git-ignored) if it is not there yet, checks out the exact revision this
# project is pinned to, and builds the release library straight into the folder the
# .gdextension file loads from.
#
#   bash native/build.sh              # release build for this host
#   TARGET=template_debug bash native/build.sh
#
# Windows: run it from Git Bash, or use native/build.cmd from a normal command prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPS="$ROOT/deps"
REV="$(cat "$ROOT/GODOT_CPP_REVISION" | tr -d '\r\n')"
SCONS="${SCONS:-scons}"
TARGET="${TARGET:-template_release}"

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
	Linux*) PLATFORM=linux ;;
	Darwin*) PLATFORM=macos ;;
	*) PLATFORM=windows ;;
esac

if [ ! -d "$DEPS/godot-cpp/.git" ]; then
	echo "native: fetching godot-cpp into $DEPS (ignored by git)"
	mkdir -p "$DEPS"
	git clone --quiet https://github.com/godotengine/godot-cpp.git "$DEPS/godot-cpp"
fi

echo "native: checking out godot-cpp $REV"
git -C "$DEPS/godot-cpp" fetch --quiet --all || true
git -C "$DEPS/godot-cpp" checkout --quiet "$REV"

echo "native: building $TARGET for $PLATFORM (api_version=4.7)"
"$SCONS" -C "$ROOT" platform="$PLATFORM" target="$TARGET" arch=x86_64 api_version=4.7 "$@"

echo "native: done - addons/pb_native/bin/"
