#!/usr/bin/env bash
# Fast parallel panorama stitching distributor
# Distributes photo sessions across multiple Docker instances for maximum speed
#
# Usage:
#   ./distribute_sessions.sh PHOTOS_DIR [PROJECT_TEMPLATE] [INSTANCES] [STITCH_FLAGS...]
#
# Example:
#   ./distribute_sessions.sh ./photos project1.pto 4 --protect-lights --clip-thr=0.998

set -euo pipefail

# Configuration
PHOTOS_DIR="${1:-./input}"
PROJECT_TEMPLATE="${2:-project1.pto}"
INSTANCES="${3:-4}"
shift 3 || true
STITCH_FLAGS=("$@")

# Validate inputs
[[ -d "$PHOTOS_DIR" ]] || { echo "ERROR: Photos directory not found: $PHOTOS_DIR"; exit 1; }
[[ -f "templates/$PROJECT_TEMPLATE" ]] || { echo "ERROR: Template not found: templates/$PROJECT_TEMPLATE"; exit 1; }

echo "Fast Parallel Panorama Stitching"
echo "================================="
echo "Photos: $PHOTOS_DIR"
echo "Template: $PROJECT_TEMPLATE" 
echo "Instances: $INSTANCES"
echo "Flags: ${STITCH_FLAGS[*]:-<none>}"
echo ""

# Find all session directories
shopt -s nullglob
mapfile -t SESSIONS < <(
  find "$PHOTOS_DIR" -mindepth 1 -maxdepth 1 -type d \( \
    -name 'photos_*' -o \
    -name 'session_*' -o \
    -name '*_session' -o \
    -name '*_photos' \
  \) | sort -V
)

# If no pattern matches, find dirs with camera files
if [[ ${#SESSIONS[@]} -eq 0 ]]; then
  mapfile -t SESSIONS < <(
    find "$PHOTOS_DIR" -mindepth 1 -maxdepth 1 -type d -exec sh -c '
      if ls "$1"/cam*.jpg >/dev/null 2>&1 || ls "$1"/photo_*.jpg >/dev/null 2>&1; then
        echo "$1"
      fi
    ' _ {} \; | sort -V
  )
fi

if [[ ${#SESSIONS[@]} -eq 0 ]]; then
  echo "ERROR: No session directories found in $PHOTOS_DIR"
  exit 1
fi

echo "Found ${#SESSIONS[@]} sessions:"
printf '   %s\n' "${SESSIONS[@]##*/}"
echo ""

# Start Docker containers if not running
echo "Starting Docker containers..."
./docker-run.sh $INSTANCES

# Wait for containers to be ready
sleep 2

# Distribute sessions across instances
PIDS=()
SESSION_COUNT=${#SESSIONS[@]}
SESSIONS_PER_INSTANCE=$(( (SESSION_COUNT + INSTANCES - 1) / INSTANCES ))

echo "Distributing $SESSION_COUNT sessions across $INSTANCES instances ($SESSIONS_PER_INSTANCE sessions per instance)"
echo ""

# Create temporary input directories for each instance
for i in $(seq 1 $INSTANCES); do
  docker exec "panorama_stitcher_$i" mkdir -p "/app/input_instance"
done

for ((i=0; i<INSTANCES; i++)); do
  INSTANCE_ID=$((i + 1))
  START_IDX=$((i * SESSIONS_PER_INSTANCE))
  END_IDX=$(( START_IDX + SESSIONS_PER_INSTANCE - 1 ))
  
  # Get sessions for this instance
  INSTANCE_SESSIONS=()
  for ((j=START_IDX; j<=END_IDX && j<SESSION_COUNT; j++)); do
    INSTANCE_SESSIONS+=("${SESSIONS[j]}")
  done
  
  if [[ ${#INSTANCE_SESSIONS[@]} -eq 0 ]]; then
    continue
  fi
  
  echo "Instance $INSTANCE_ID processing ${#INSTANCE_SESSIONS[@]} sessions:"
  printf '   %s\n' "${INSTANCE_SESSIONS[@]##*/}"
  
  # Copy only assigned sessions to this instance's input directory
  for session in "${INSTANCE_SESSIONS[@]}"; do
    session_name=$(basename "$session")
    echo "   Copying $session_name to instance $INSTANCE_ID"
    docker exec "panorama_stitcher_$INSTANCE_ID" cp -r "/app/input/$session_name" "/app/input_instance/"
  done
  
  # Build command for this instance - use instance-specific input directory
  CMD=(
    docker exec "panorama_stitcher_$INSTANCE_ID" 
    ./batch_stitch.sh 
    "templates/$PROJECT_TEMPLATE"
    "/app/input_instance"
    "/app/output"
  )
  
  # Add stitch flags if provided
  if [[ ${#STITCH_FLAGS[@]} -gt 0 ]]; then
    CMD+=("--" "${STITCH_FLAGS[@]}")
  fi
  
  # Run in background and capture PID
  "${CMD[@]}" &
  PIDS+=($!)
  
  echo "   Started (PID: $!)"
  echo ""
done

# Wait for all instances to complete
echo "Waiting for all instances to complete..."
COMPLETED=0
FAILED=0

for pid in "${PIDS[@]}"; do
  if wait "$pid"; then
    COMPLETED=$((COMPLETED + 1))
    echo "Instance completed successfully"
  else
    FAILED=$((FAILED + 1))
    echo "Instance failed"
  fi
done

echo ""
echo "Parallel Processing Complete!"
echo "============================"
echo "Completed: $COMPLETED instances"
echo "Failed: $FAILED instances"
echo ""

# Collect results from all instance directories
echo "Collecting results from instance directories..."
OUTPUT_DIR="./output"
mkdir -p "$OUTPUT_DIR"

# Copy panoramas from containers to main output
mkdir -p "$OUTPUT_DIR/final_panoramas"

for i in $(seq 1 $INSTANCES); do
  echo "   Collecting results from container panorama_stitcher_$i..."
  
  # Copy all files from container to temporary instance directory
  INSTANCE_DIR="$OUTPUT_DIR/instance_$i"
  mkdir -p "$INSTANCE_DIR"
  docker cp "panorama_stitcher_$i:/app/output/." "$INSTANCE_DIR/" 2>/dev/null || true
  
  # Find and copy only the final panorama files (both .tif and .tiff extensions)
  # Copy files that end with timestamp pattern (YYYYMMDD_HHMMSS.tif/tiff) but not with 4-digit suffix
  find "$INSTANCE_DIR" -name "pano_*_[0-9][0-9][0-9][0-9][0-9][0-9].tif" -exec cp {} "$OUTPUT_DIR/final_panoramas/" \; 2>/dev/null || true
  find "$INSTANCE_DIR" -name "pano_*_[0-9][0-9][0-9][0-9][0-9][0-9].tiff" -exec cp {} "$OUTPUT_DIR/final_panoramas/" \; 2>/dev/null || true
done

# Find all final panorama files that were collected
RESULT_FILES=()
while IFS= read -r -d '' file; do
  RESULT_FILES+=("$file")
done < <(find "$OUTPUT_DIR/final_panoramas" -name "*.tif" -o -name "*.tiff" -o -name "*.jpg" -o -name "*.png" -print0 2>/dev/null)

# Show results
if [[ ${#RESULT_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "Generated ${#RESULT_FILES[@]} panorama files:"
  printf '   %s\n' "${RESULT_FILES[@]}"
else
  echo "WARNING: No panorama files found"
fi

# Clean up temporary directories
echo ""
echo "Cleaning up temporary directories..."
for i in $(seq 1 $INSTANCES); do
  rm -rf "temp/instance_$i" 2>/dev/null || true
  rm -rf "$OUTPUT_DIR/instance_$i" 2>/dev/null || true
  # Clean up input_instance directories inside containers
  docker exec "panorama_stitcher_$i" rm -rf "/app/input_instance" 2>/dev/null || true
done

echo ""
echo "Final panoramas saved to: $OUTPUT_DIR/final_panoramas/"

echo ""
echo "Processing completed in parallel across $INSTANCES instances!"
