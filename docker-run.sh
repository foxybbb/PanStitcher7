#!/usr/bin/env bash
# Simple Docker runner without Docker Compose
# Starts multiple panorama stitcher containers using plain Docker commands

set -euo pipefail

INSTANCES="${1:-4}"
echo "Starting $INSTANCES Docker containers for panorama stitching..."

# Build the image first
echo "Building panorama stitcher image..."
if ! docker build -t panorama-stitcher .; then
  echo "ERROR: Failed to build Docker image"
  exit 1
fi

# Create network for containers
docker network create panorama-network 2>/dev/null || true

# Create instance-specific directories
echo "Creating instance-specific directories..."
mkdir -p output
for i in $(seq 1 $INSTANCES); do
  mkdir -p "output/instance_$i"
  mkdir -p "temp/instance_$i"
done

# Start containers
CONTAINER_IDS=()
for i in $(seq 1 $INSTANCES); do
  echo "Starting container $i..."
  
  # Remove existing container if it exists
  docker rm -f "panorama_stitcher_$i" 2>/dev/null || true
  
  # Start new container with instance-specific volumes
  CONTAINER_ID=$(docker run -d \
    --name "panorama_stitcher_$i" \
    --network panorama-network \
    -v "$(pwd)/input:/app/input:ro" \
    -v "$(pwd)/output/instance_$i:/app/output" \
    -v "$(pwd)/temp/instance_$i:/app/temp" \
    -v "$(pwd)/templates:/app/templates:ro" \
    -e "INSTANCE_ID=$i" \
    -e "KEEP_TMP=0" \
    -e "TMPDIR=/app/temp" \
    panorama-stitcher \
    bash -c "echo 'Stitcher $i ready with isolated dirs.' && sleep infinity")
  
  CONTAINER_IDS+=("$CONTAINER_ID")
  echo "   Container $i started: $CONTAINER_ID"
done

echo ""
echo "All $INSTANCES containers are ready!"
echo "Container names: panorama_stitcher_1 to panorama_stitcher_$INSTANCES"
echo ""
echo "Usage:"
echo "  ./distribute_sessions.sh ./input project1.pto $INSTANCES"
echo ""
echo "To stop all containers:"
echo "  ./docker-stop.sh"
