#!/usr/bin/env bash
# Batch runner for Hugin stitching across session folders in Docker environment.
# Usage:
#   ./batch_stitch.sh BASE.pto PHOTOS_ROOT OUT_DIR [--no-crop] [-- ...flags for stitch.sh...]
#
# Examples:
#   ./batch_stitch.sh templates/project1.pto ./input/batch_job_id ./output/batch_job_id --no-crop -- --protect-lights --clip-thr=0.998 --clip-pct=0.0005
#
# Notes:
# - All additional flags after `--` are passed through to stitch.sh.
# - Auto-renaming in each session:
#     photo_rpihelmetX_*.jpg     -> camX_*.jpg
#     camX_rpihelmetX_*.jpg      -> camX_*.jpg
# - Supports flexible naming patterns for photo sessions

set -euo pipefail

# --- dependencies ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }
need grep
need sed
need awk
need find
need sort
need readlink
need mktemp

# Stitcher script location
STITCH="/app/stitch.sh"
if ! command -v "$STITCH" >/dev/null 2>&1; then
  if [[ -x "$STITCH" ]]; then :; else
    echo "stitch.sh not found (in PATH or current directory)."; exit 1
  fi
fi

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 BASE.pto PHOTOS_ROOT OUT_DIR [--no-crop] [-- ...flags for stitch.sh...]"
  exit 1
fi

BASE_PTO="$1"; shift
PHOTOS_ROOT="$1"; shift
OUT_DIR="$1"; shift

[[ -f "$BASE_PTO" ]]    || { echo "Project file not found: $BASE_PTO"; exit 1; }
[[ -d "$PHOTOS_ROOT" ]] || { echo "Photos directory not found: $PHOTOS_ROOT"; exit 1; }
mkdir -p "$OUT_DIR"

# --- parse options and collect flags for stitch.sh ---
NO_CROP=0
STITCH_FLAGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-crop) NO_CROP=1; shift ;;
    --) shift; while [[ $# -gt 0 ]]; do STITCH_FLAGS+=("$1"); shift; done ;;
    *) STITCH_FLAGS+=("$1"); shift ;;
  esac
done

# --- create temporary PTO copy with r:FULL if needed ---
TMPDIR_RUN="$(mktemp -d -t pano_run_XXXXXX)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

PTO_FOR_RUN="$BASE_PTO"
if [[ "$NO_CROP" -eq 1 ]]; then
  PTO_FOR_RUN="$TMPDIR_RUN/$(basename "${BASE_PTO%.pto}")__nocrop.pto"
  cp -f "$BASE_PTO" "$PTO_FOR_RUN"
  # Replace r:CROP with r:FULL in p-lines
  sed -i 's/r:CROP/r:FULL/g' "$PTO_FOR_RUN"
fi

# How many cameras does the PTO expect (by number of i-lines)
PTO_N_IMAGES=$(grep -E '^[[:space:]]*i[[:space:]]' "$PTO_FOR_RUN" | wc -l | tr -d ' ')
[[ "$PTO_N_IMAGES" -gt 0 ]] || { echo "No images found in project (i-lines)."; exit 1; }

echo "PTO:         $PTO_FOR_RUN (orig: $BASE_PTO)"
echo "PHOTOS_ROOT: $PHOTOS_ROOT"
echo "OUT_DIR:     $OUT_DIR"
echo "Cams in PTO: $PTO_N_IMAGES"
echo "no-crop:     $NO_CROP"
echo "Flags -> stitch.sh: ${STITCH_FLAGS[*]:-<none>}"
echo "-----------------------------------------------"

# Function to rename files in a session directory
rename_in_session() {
  local sess="$1"
  echo "Renaming files in session: $sess"
  
  # 1) photo_rpihelmetX_... -> camX_...
  find "$sess" -maxdepth 1 -type f -iname 'photo_rpihelmet*.jpg' -print0 | \
  xargs -0 -I{} bash -c '
    f="$1"
    new="${f/photo_rpihelmet/cam}"
    if [[ "$f" != "$new" ]]; then
      echo "Renaming: $(basename "$f") -> $(basename "$new")"
      mv -- "$f" "$new"
    fi
  ' _ {}

  # 2) camX_rpihelmetX_... -> camX_...
  find "$sess" -maxdepth 1 -type f -iname 'cam*_rpihelmet*.jpg' -print0 | \
  xargs -0 -I{} bash -c '
    f="$1"
    new="$(echo "$f" | sed -E "s/cam([0-9]+)_rpihelmet[0-9]+_/cam\\1_/")"
    if [[ "$f" != "$new" ]]; then
      echo "Renaming: $(basename "$f") -> $(basename "$new")"
      mv -- "$f" "$new"
    fi
  ' _ {}

  # 3) Handle timestamp suffixes: camX_TIMESTAMP.jpg -> keep as is (already good)
  # 4) Ensure we have at least camX.jpg or camX_*.jpg for each camera
  
  echo "Files after renaming:"
  ls -la "$sess"/ | grep -E '\.(jpg|jpeg|png|tif|tiff)$' || echo "No image files found"
}

# Function to check if session has all required cameras
has_all_cams() {
  local sess="$1" n="$2"
  local idx missing=0
  
  for idx in $(seq 1 "$n"); do
    # Check for camX.jpg or camX_*.jpg
    if ! compgen -G "$sess/cam${idx}.jpg" >/dev/null && \
       ! compgen -G "$sess/cam${idx}_*.jpg" >/dev/null; then
      echo "WARNING: [$sess] missing file for cam$idx" >&2
      missing=$((missing + 1))
    fi
  done
  
  if [[ $missing -gt 0 ]]; then
    echo "Missing $missing cameras in session $(basename "$sess")" >&2
    return 1
  fi
  return 0
}

# Function to get session output prefix
get_output_prefix() {
  local sess="$1" out_dir="$2"
  local base="$(basename "$sess")"
  
  # Handle different naming patterns
  if [[ "$base" =~ ^photos_(.+)$ ]]; then
    echo "$out_dir/pano_${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^session_(.+)$ ]]; then
    echo "$out_dir/pano_${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^(.+)_session$ ]]; then
    echo "$out_dir/pano_${BASH_REMATCH[1]}"
  else
    echo "$out_dir/pano_$base"
  fi
}

# --- process sessions ---
shopt -s nullglob

# Find session directories with flexible patterns
mapfile -t SESSIONS < <(
  find "$PHOTOS_ROOT" -mindepth 1 -maxdepth 1 -type d \( \
    -name 'photos_*' -o \
    -name 'session_*' -o \
    -name '*_session' -o \
    -name '*_photos' -o \
    -name 'capture_*' -o \
    -name '*_capture' \
  \) | sort -V
)

# If no sessions found with patterns, try any directory with camera files
if [[ ${#SESSIONS[@]} -eq 0 ]]; then
  echo "No session directories found with standard patterns, checking for directories with camera files..."
  mapfile -t SESSIONS < <(
    find "$PHOTOS_ROOT" -mindepth 1 -maxdepth 1 -type d -exec sh -c '
      if ls "$1"/cam*.jpg >/dev/null 2>&1 || ls "$1"/photo_*.jpg >/dev/null 2>&1; then
        echo "$1"
      fi
    ' _ {} \; | sort -V
  )
fi

if [[ ${#SESSIONS[@]} -eq 0 ]]; then
  echo "No session directories found in $PHOTOS_ROOT"
  echo "Looking for directories containing:"
  echo "  - photos_* pattern"
  echo "  - session_* pattern" 
  echo "  - *_session pattern"
  echo "  - directories with cam*.jpg or photo_*.jpg files"
  exit 1
fi

echo "Found ${#SESSIONS[@]} session(s) to process:"
printf '%s\n' "${SESSIONS[@]}"
echo ""

# Process each session
PROCESSED=0
FAILED=0

for sess in "${SESSIONS[@]}"; do
  base="$(basename "$sess")"
  out_prefix="$(get_output_prefix "$sess" "$OUT_DIR")"

  echo -e "\n== Session: $base =="
  echo "Folder: $sess"
  echo "Output: $out_prefix"
  
  # Rename files in the session
  rename_in_session "$sess"

  # Check if we have all required cameras
  if ! has_all_cams "$sess" "$PTO_N_IMAGES"; then
    echo "SKIPPING session $base - missing cameras (expected $PTO_N_IMAGES)."
    FAILED=$((FAILED + 1))
    continue
  fi

  # Run the stitcher
  echo "Starting stitcher for session $base..."
  if KEEP_TMP=0 "$STITCH" "${STITCH_FLAGS[@]}" "$PTO_FOR_RUN" "$out_prefix" "$sess"; then
    echo "Session $base completed successfully"
    PROCESSED=$((PROCESSED + 1))
  else
    echo "Session $base failed"
    FAILED=$((FAILED + 1))
  fi
done

echo -e "\n================================================"
echo "Batch processing completed!"
echo "Processed: $PROCESSED sessions"
echo "Failed: $FAILED sessions"
echo "Output directory: $OUT_DIR"
echo "================================================"

if [[ $PROCESSED -gt 0 ]]; then
  echo -e "\nGenerated panoramas:"
  find "$OUT_DIR" -name "*.tif" -o -name "*.jpg" -o -name "*.png" | sort
fi

exit 0
