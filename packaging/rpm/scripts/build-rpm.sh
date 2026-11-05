#!/usr/bin/env bash
set -euo pipefail

# packaging/rpm/scripts/build-rpm.sh
# Downloads Debian releases from upstream and packages them as RPMs.

UPSTREAM_REPO="${UPSTREAM_REPO:-pingdotgg/t3code}"
OUTPUT_DIR=""
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --upstream-repo)
      UPSTREAM_REPO="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "Error: --tag is required (e.g. --tag v0.1.7)" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pwd)/release-rpm"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

VERSION="${TAG#v}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

echo "Fetching release info for tag $TAG from $UPSTREAM_REPO..."
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/tags/${TAG}")"

# Map deb asset suffixes to target rpm architectures
declare -A ARCH_MAP=(
  ["amd64"]="x86_64"
  ["arm64"]="aarch64"
)

# Determine whether to run alien via fakeroot or directly
RUN_ALIEN="alien"
if [[ "$(id -u)" != 0 ]] && command -v fakeroot >/dev/null 2>&1; then
  RUN_ALIEN="fakeroot alien"
fi

for DEB_ARCH in "${!ARCH_MAP[@]}"; do
  RPM_ARCH="${ARCH_MAP[$DEB_ARCH]}"
  DEB_NAME="T3-Code-${VERSION}-${DEB_ARCH}.deb"

  # Find asset download URL using jq
  DOWNLOAD_URL="$(jq -r --arg name "$DEB_NAME" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$RELEASE_JSON")"

  if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    echo "Warning: Asset $DEB_NAME not found for tag $TAG in $UPSTREAM_REPO. Skipping $RPM_ARCH."
    continue
  fi

  echo "Downloading $DEB_NAME..."
  DEB_FILE="$WORK_DIR/$DEB_NAME"
  curl -fsSL --retry 3 -o "$DEB_FILE" "$DOWNLOAD_URL"

  echo "Converting $DEB_NAME to RPM using $RUN_ALIEN..."
  (
    cd "$WORK_DIR"
    $RUN_ALIEN --to-rpm --scripts --keep-version "$DEB_FILE"
  )

  # Find generated rpm file in WORK_DIR
  GENERATED_RPM="$(find "$WORK_DIR" -maxdepth 1 -name "*.rpm" -print -quit)"
  if [[ -z "$GENERATED_RPM" || ! -f "$GENERATED_RPM" ]]; then
    echo "Error: RPM was not generated for $DEB_NAME." >&2
    exit 1
  fi

  FINAL_RPM_NAME="t3code-${VERSION}-1.${RPM_ARCH}.rpm"
  mv "$GENERATED_RPM" "$OUTPUT_DIR/$FINAL_RPM_NAME"
  echo "Successfully generated $OUTPUT_DIR/$FINAL_RPM_NAME"
done

# Generate SHA256 checksums
cd "$OUTPUT_DIR"
shopt -s nullglob
RPM_FILES=(*.rpm)
if [[ ${#RPM_FILES[@]} -eq 0 ]]; then
  echo "Error: No RPM files were generated." >&2
  exit 1
fi

sha256sum "${RPM_FILES[@]}" > SHA256SUMS-RPM
echo "Generated SHA256 checksums:"
cat SHA256SUMS-RPM
