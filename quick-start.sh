#!/usr/bin/env bash
# Quick start script for fast parallel panorama stitching
# This is the simplest way to process your photos with maximum speed

set -euo pipefail

echo "Quick Start - Fast Parallel Panorama Stitching"
echo "=============================================="

# Check if photos directory exists
if [[ ! -d "./input" ]]; then
  echo "Creating input directory..."
  mkdir -p ./input
  echo "   Please copy your photos/ folder to ./input/"
  echo "   Example: cp -r /path/to/your/photos ./input/"
  echo ""
fi

# Check if we have photos
if [[ ! -d "./input/photos" ]] && [[ $(find ./input -maxdepth 1 -type d -name "photos_*" | wc -l) -eq 0 ]]; then
  echo "ERROR: No photos found in ./input/"
  echo ""
  echo "Setup Instructions:"
  echo "1. Copy your photos to ./input/"
  echo "   cp -r /path/to/your/photos ./input/"
  echo ""
  echo "2. Run this script again:"
  echo "   ./quick-start.sh"
  echo ""
  exit 1
fi

# Create output directory
mkdir -p ./output

echo "Found photos in ./input/"
echo "Counting sessions..."

# Count sessions
SESSION_COUNT=$(find ./input -mindepth 1 -maxdepth 1 -type d \( -name 'photos_*' -o -name 'session_*' \) | wc -l)
if [[ $SESSION_COUNT -eq 0 ]]; then
  SESSION_COUNT=$(find ./input -mindepth 1 -maxdepth 1 -type d -exec sh -c 'ls "$1"/cam*.jpg >/dev/null 2>&1' _ {} \; -print | wc -l)
fi

echo "Found $SESSION_COUNT photo sessions"

# Determine optimal instance count
if [[ $SESSION_COUNT -le 2 ]]; then
  INSTANCES=2
elif [[ $SESSION_COUNT -le 4 ]]; then
  INSTANCES=2
elif [[ $SESSION_COUNT -le 8 ]]; then
  INSTANCES=4
else
  INSTANCES=4
fi

echo "Using $INSTANCES parallel instances for optimal speed"
echo ""

# Start processing
echo "Building and starting Docker containers..."
if ! ./docker-run.sh $INSTANCES; then
  echo "ERROR: Failed to start Docker containers"
  echo "   Make sure Docker is running and try again"
  exit 1
fi

echo ""
echo "Starting parallel panorama stitching..."
echo "   This will process $SESSION_COUNT sessions across $INSTANCES instances"
echo "   Estimated time: $((SESSION_COUNT * 2 / INSTANCES)) minutes"
echo ""

# Start distribution script
if ./distribute_sessions.sh ./input project1.pto $INSTANCES --protect-lights --clip-thr=0.998; then
  echo ""
  echo "SUCCESS! All panoramas completed!"
  echo ""
  echo "Results are in ./output/final_panoramas/"
  echo "   $(find ./output/final_panoramas -name "*.tif" -o -name "*.tiff" -o -name "*.jpg" -o -name "*.png" 2>/dev/null | wc -l) panorama files generated"
  echo ""
  echo "Cleaning up containers..."
  ./docker-stop.sh
  echo ""
  echo "Done! Check ./output/final_panoramas/ for your panoramas"
else
  echo ""
  echo "ERROR: Some sessions failed to process"
  echo "   Check ./output/final_panoramas/ for completed panoramas"
  echo "   $(find ./output/final_panoramas -name "*.tif" -o -name "*.tiff" -o -name "*.jpg" -o -name "*.png" 2>/dev/null | wc -l) panorama files generated"
  echo "   Containers are still running for debugging"
  echo "   Run: docker logs panorama_stitcher_1"
fi
