#!/usr/bin/env bash
# Builds the two APKs this repo ships, from CleanYourTV's source plus the patches in this folder.
#
#   ./build.sh               both
#   ./build.sh launcher      TV Home with the Christmas season   -> dist/christmas-tv-home.apk
#   ./build.sh smart-home    the Smart Home add-on               -> dist/smart-home-addon.apk
#
# You need git, curl and Docker. The Android SDK and Gradle run in a throwaway eclipse-temurin
# container, so nothing is installed on your machine. It's an amd64 container because Google's Linux
# build tools are x86-64 only; Docker Desktop and OrbStack run it under emulation on Apple silicon.
# The SDK and the Gradle cache live in two Docker volumes, so only the first build is slow
# (about 10 minutes).
#
# The APKs are signed with the Android debug key in ~/.android (Gradle makes one if there isn't one
# yet). If you already run TV Home from your own CleanYourTV build, that's the key it was signed with,
# so this build installs straight over it. ANDROID_KEYS=/some/folder uses another debug.keystore.
#
# Before anything is built, each upstream tag is checked against the commit these patches were made
# for (tags can be moved), and Gradle's wrapper jar against Gradle's published checksum.
set -euo pipefail

HERE="$(cd -P "$(dirname "$0")" && pwd)"
REPO="https://github.com/Gathin23/cleanyourtv.git"
WORK="$HERE/build"
DIST="$HERE/dist"
IMAGE="eclipse-temurin:17-jdk"
CLT="commandlinetools-linux-11076708_latest.zip"
SDK_VOLUME="${SDK_VOLUME:-christmas-tv-home-sdk}"
GRADLE_VOLUME="${GRADLE_VOLUME:-christmas-tv-home-gradle}"
ANDROID_KEYS="${ANDROID_KEYS:-$HOME/.android}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

for tool in git curl docker; do
  command -v "$tool" >/dev/null || die "$tool isn't installed"
done

# build NAME TAG COMMIT SUBFOLDER PATCH_DIR "GRADLE TASKS" OUTPUT_NAME
build() {
  local name="$1" tag="$2" commit="$3" sub="$4" patches="$5" tasks="$6" out="$7"
  local src="$WORK/cleanyourtv-$tag" props ver want have p

  say "== $name"
  mkdir -p "$WORK" "$DIST" "$ANDROID_KEYS"
  if [ ! -d "$src/.git" ]; then
    say "Fetching CleanYourTV $tag..."
    git clone -q --depth 1 --branch "$tag" "$REPO" "$src"
  fi
  [ "$(git -C "$src" rev-parse HEAD)" = "$commit" ] \
    || die "CleanYourTV's $tag tag no longer points at $commit, the commit these patches were made for."

  props="$src/$sub/gradle/wrapper/gradle-wrapper.properties"
  ver="$(sed -n 's/.*gradle-\([0-9.]*\)-bin\.zip.*/\1/p' "$props")"
  want="$(curl -fsSL "https://services.gradle.org/distributions/gradle-$ver-wrapper.jar.sha256")"
  have="$(sha256 "$src/$sub/gradle/wrapper/gradle-wrapper.jar")"
  [ -n "$want" ] && [ "$want" = "$have" ] || die "gradle-wrapper.jar doesn't match Gradle $ver's published checksum"
  grep -q '^distributionSha256Sum=' "$props" || die "the Gradle download isn't hash-pinned in $props"

  # Back to pristine upstream (including files an earlier run's patches added), then patch.
  git -C "$src" checkout -q -- .
  git -C "$src" clean -fdq -- "$sub/app/src"
  for p in "$patches"/*.patch; do
    git -C "$src" apply --whitespace=nowarn "$p" || die "$(basename "$p") doesn't apply to CleanYourTV $tag"
    say "applied $(basename "$p")"
  done

  say "Building (the first run downloads the Android SDK and Gradle)..."
  docker run --rm --platform linux/amd64 \
    -v "$SDK_VOLUME:/sdk" -v "$GRADLE_VOLUME:/root/.gradle" -v "$ANDROID_KEYS:/root/.android" \
    -v "$src:/src" -w "/src/$sub" \
    -e ANDROID_HOME=/sdk -e CLT="$CLT" -e TASKS="$tasks" -e OWNER="$(id -u):$(id -g)" -e DEBIAN_FRONTEND=noninteractive \
    "$IMAGE" bash -euo pipefail -c '
      command -v unzip >/dev/null || { apt-get update -qq && apt-get install -y -qq unzip >/dev/null; }
      if [ ! -x /sdk/cmdline-tools/latest/bin/sdkmanager ]; then
        curl -fsSL -o /tmp/clt.zip "https://dl.google.com/android/repository/$CLT"
        mkdir -p /sdk/cmdline-tools && unzip -q /tmp/clt.zip -d /sdk/cmdline-tools
        mv /sdk/cmdline-tools/cmdline-tools /sdk/cmdline-tools/latest
      fi
      # `yes` dies of SIGPIPE once sdkmanager stops reading; pipefail would call that a failure.
      (set +o pipefail; yes | /sdk/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null)
      /sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-34" "build-tools;34.0.0" >/dev/null
      status=0
      ./gradlew --no-daemon --no-watch-fs -q --console=plain $TASKS || status=$?
      # On Linux the container writes as root; hand the build output and the key back to you.
      chown -R "$OWNER" /src /root/.android 2>/dev/null || true
      exit $status
    '
  cp "$src/$sub/app/build/outputs/apk/release/app-release.apk" "$DIST/$out"
  say "Built dist/$out"
  say "sha256 $(sha256 "$DIST/$out")"
}

what="${1:-all}"
case "$what" in
  all|launcher|smart-home) ;;
  *) die "usage: ./build.sh [launcher|smart-home]" ;;
esac
if [ "$what" = all ] || [ "$what" = launcher ]; then
  build "TV Home with the Christmas season" v3.5.0 d11bd68c9ac45b2fb38480941586d17930137e9d \
    launcher "$HERE/launcher/patches" "testReleaseUnitTest assembleRelease" christmas-tv-home.apk
fi
if [ "$what" = all ] || [ "$what" = smart-home ]; then
  build "Smart Home add-on" v3.5.0 d11bd68c9ac45b2fb38480941586d17930137e9d \
    addons/smart-home "$HERE/smart-home/patches" "testReleaseUnitTest assembleRelease" smart-home-addon.apk
fi
