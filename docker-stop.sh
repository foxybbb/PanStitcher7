#!/usr/bin/env bash
# Stop and clean up all panorama stitcher containers

set -euo pipefail

echo "Stopping panorama stitcher containers..."

# Find and stop all panorama stitcher containers
CONTAINERS=$(docker ps -a --filter "name=panorama_stitcher_" --format "{{.Names}}" | sort)

if [[ -z "$CONTAINERS" ]]; then
  echo "No panorama stitcher containers found"
else
  echo "Found containers: $CONTAINERS"
  
  for container in $CONTAINERS; do
    echo "Stopping $container..."
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm "$container" >/dev/null 2>&1 || true
    echo "   Removed $container"
  done
fi

# Clean up network
echo "Cleaning up network..."
docker network rm panorama-network >/dev/null 2>&1 || true

echo "All containers stopped and cleaned up!"

