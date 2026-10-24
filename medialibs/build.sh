#!/bin/bash


PROGNAME=$(basename "$0")

SCRIPT_VERSION=1.0.0

CWD=$(cd "$(dirname "$0")" && pwd)
PACKAGES="$CWD/packages"
WORKSPACE="$CWD/workspace"
LATEST=false
CURRENT_PACKAGE_VERSION=0


command_exists() {
  if ! [[ -x $(command -v "$1") ]]; then
    return 1
  fi

  return 0
}

if [[ "$OSTYPE" != "darwin"* ]]; then
  echo "This script only supports macOS."
  exit 1
fi

# Check for Apple Silicon
if [[ "$(uname -m)" == "arm64" ]]; then
  export ARCH=arm64
  VPX_TARGET=arm64-darwin25-gcc
  echo "Apple Silicon detected."
else
  export ARCH=x86_64
  VPX_TARGET=x86_64-darwin24-gcc
  echo "Intel Mac detected."
fi

# Match the app's deployment target.
export MACOSX_DEPLOYMENT_TARGET=27.0
echo "macOS Version: $(sw_vers -productVersion), deployment target: $MACOSX_DEPLOYMENT_TARGET"

# Speed up the process
# Env Var NUMJOBS overrides automatic detection
if [[ -n "$NUMJOBS" ]]; then
  MJOBS="$NUMJOBS"
else
  MJOBS=$(sysctl -n hw.ncpu)
fi

make_dir() {
  remove_dir "$1"
  if ! mkdir "$1"; then
    printf "\n Failed to create dir %s" "$1"
    exit 1
  fi
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -rf "$1"
  fi
}

download() {
  # download url [filename[dirname]]

  DOWNLOAD_PATH="$PACKAGES"
  DOWNLOAD_FILE="${2:-"${1##*/}"}"

  if [[ "$DOWNLOAD_FILE" =~ tar. ]]; then
    TARGETDIR="${DOWNLOAD_FILE%.*}"
    TARGETDIR="${3:-"${TARGETDIR%.*}"}"
  else
    TARGETDIR="${3:-"${DOWNLOAD_FILE%.*}"}"
  fi

  if [ ! -f "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ] || [ ! -s "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
    echo "Downloading $1 as $DOWNLOAD_FILE"

    MAX_RETRIES=2
    RETRY_COUNT=0
    SUCCESS=false

    while [ $RETRY_COUNT -le $MAX_RETRIES ]; do
      if [ $RETRY_COUNT -gt 0 ]; then
        echo "Retrying download (attempt $((RETRY_COUNT + 1))/$((MAX_RETRIES + 1))) in 10 seconds..."
        sleep 10
      fi

      curl -L --silent --fail -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"
      EXITCODE=$?

      if [ $EXITCODE -eq 0 ] && [ -s "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
        SUCCESS=true
        break
      fi

      echo "Failed to download $1 (Exitcode $EXITCODE or empty file)"
      RETRY_COUNT=$((RETRY_COUNT + 1))
    done

    if [ "$SUCCESS" = false ]; then
      echo "Failed to download $1 after $((MAX_RETRIES + 1)) attempts."
      exit 1
    fi

    echo "... Done"
  else
    echo "$DOWNLOAD_FILE has already been downloaded and is not empty."
  fi

  make_dir "$DOWNLOAD_PATH/$TARGETDIR"

  if ! tar -xf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" --strip-components 1 2>/dev/null >/dev/null; then
    echo "Failed to extract $DOWNLOAD_FILE"
    exit 1
  fi

  echo "Extracted $DOWNLOAD_FILE"

  cd "$DOWNLOAD_PATH/$TARGETDIR" || {
    echo "Error has occurred."
    exit 1
  }
}

execute() {
  echo "$ $*"

  OUTPUT=$("$@" 2>&1)

  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    echo "$OUTPUT"
    echo ""
    echo "Failed to Execute $*" >&2
    exit 1
  fi
}

build() {
  echo ""
  echo "building $1 - version $2"
  echo "======================="
  CURRENT_PACKAGE_VERSION=$2

  if [ -f "$PACKAGES/$1.done" ]; then
    if grep -Fx "$2" "$PACKAGES/$1.done" >/dev/null; then
      echo "$1 version $2 already built. Remove $PACKAGES/$1.done lockfile to rebuild it."
      return 1
    elif $LATEST; then
      echo "$1 is outdated and will be rebuilt with latest version $2"
      return 0
    else
      echo "$1 is outdated, but will not be rebuilt. Pass in --latest to rebuild it or remove $PACKAGES/$1.done lockfile."
      return 1
    fi
  fi

  return 0
}

build_done() {
  echo "$2" >"$PACKAGES/$1.done"
}

cleanup() {
  remove_dir "$PACKAGES"
  remove_dir "$WORKSPACE"
  echo "Cleanup done."
  echo ""
}

usage() {
  echo "Usage: $PROGNAME [OPTIONS]"
  echo "Options:"
  echo "  -h, --help                     Display usage information"
  echo "      --version                  Display version information"
  echo "  -b, --build                    Starts the build process"
  echo "  -c, --cleanup                  Remove all working dirs"
  echo "      --latest                   Rebuild packages whose version changed"
  echo ""
}

echo "media-libs-build-script v$SCRIPT_VERSION"
echo "========================="
echo ""

while (($# > 0)); do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  --version)
    echo "$SCRIPT_VERSION"
    exit 0
    ;;
  -b | --build)
    bflag='-b'
    shift
    ;;
  -c | --cleanup)
    cflag='-c'
    cleanup
    shift
    ;;
  --latest)
    LATEST=true
    shift
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

if [ -z "$bflag" ]; then
  if [ -z "$cflag" ]; then
    usage
    exit 1
  fi
  exit 0
fi

echo "Using $MJOBS make jobs simultaneously."

mkdir -p "$PACKAGES"
mkdir -p "$WORKSPACE"

# Prefer the cmake built by ../tdlib/build.sh.
export PATH="${WORKSPACE}/bin:${CWD}/../tdlib/workspace/bin:$PATH"

if ! command_exists "make"; then
  echo "make not installed."
  exit 1
fi

if ! command_exists "clang++"; then
  echo "clang++ is not installed. Please install Xcode Command Line Tools."
  exit 1
fi

if ! command_exists "cmake"; then
  echo "cmake not found. Run ../tdlib/build.sh -b first or install cmake."
  exit 1
fi

if ! command_exists "perl"; then
  echo "perl not installed. It is required to configure libvpx."
  exit 1
fi

##
## libraries
##

# Renders TGS (Lottie) stickers. The last release (v0.2) is from 2020, so a master commit is pinned.
RLOTTIE_COMMIT=ea06d2f29ba01b8d06c00a838d107f5e484ae59b
if build "rlottie" "$RLOTTIE_COMMIT"; then
  download "https://github.com/Samsung/rlottie/archive/$RLOTTIE_COMMIT.tar.gz" "rlottie-$RLOTTIE_COMMIT.tar.gz"
  make_dir build
  cd build || exit 1
  # rlottie's NEON path needs pixman assembly that its CMake only builds for 32-bit ARM, so use the C path.
  execute cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLIB_INSTALL_DIR="${WORKSPACE}/lib" -DBUILD_SHARED_LIBS=OFF -DLOTTIE_MODULE=OFF -DLOTTIE_TEST=OFF -DLOTTIE_THREAD=ON \
    -DCMAKE_C_FLAGS="-U__ARM_NEON__" -DCMAKE_CXX_FLAGS="-U__ARM_NEON__"
  execute make -j "$MJOBS"
  execute make install
  build_done "rlottie" $CURRENT_PACKAGE_VERSION
fi

# Decodes VP9 (with alpha) for WebM video stickers. Decoder only.
if build "libvpx" "1.17.0"; then
  download "https://github.com/webmproject/libvpx/archive/refs/tags/v$CURRENT_PACKAGE_VERSION.tar.gz" "libvpx-$CURRENT_PACKAGE_VERSION.tar.gz"
  execute ./configure --prefix="${WORKSPACE}" --target="$VPX_TARGET" \
    --disable-shared --enable-static --enable-pic \
    --disable-vp8 --enable-vp9 --disable-vp9-encoder --enable-vp9-decoder \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
  execute make -j "$MJOBS"
  execute make install
  build_done "libvpx" $CURRENT_PACKAGE_VERSION
fi

cd "$CWD" || exit 1

echo ""
echo "media libraries Building DONE."
echo ""
ls -l "${WORKSPACE}/lib"/*.a
echo ""
echo "Run ../build-libs.sh to collect them into libs/, which the app links from."
echo ""

exit 0
