# Simple Fast Panorama Stitcher

A simplified, ultra-fast Docker setup for parallel panorama stitching on local machines. No APIs, no queues - just pure speed.

## ⚡ Quick Start (30 seconds)

```bash
# 1. Copy your photos
cp -r /path/to/your/photos ./input/

# 2. Run everything
./quick-start.sh
```

That's it! Your panoramas will be in `./output/` folder.

## 🏗️ Architecture

**Simple & Fast:**
- 4 Docker containers running in parallel
- Each container processes different photo sessions
- Direct file sharing via mounted volumes
```
Your Photos → [Container 1] → Panorama 1, 2, 3
           → [Container 2] → Panorama 4, 5, 6  
           → [Container 3] → Panorama 7, 8, 9
           → [Container 4] → Panorama 10, 11
```


## 🔧 Manual Usage

### Method 1: One Command
```bash
# Copy your photos and run
cp -r /path/to/your/photos ./input/
./quick-start.sh
```

### Method 2: Step by Step
```bash
# 1. Start containers
./docker-run.sh 4

# 2. Distribute work across instances
./distribute_sessions.sh ./input project1.pto 4 --protect-lights --clip-thr=0.998

# 3. Clean up
./docker-stop.sh
```

### Method 3: Custom Settings
```bash
# Start containers
./docker-run.sh 2

# Custom processing with different template and flags
./distribute_sessions.sh ./input project2.pto 2 --no-crop -- --protect-lights --clip-thr=0.999

# Results in ./output/
ls -la ./output/
```

## 📁 Folder Structure

```
PanStitcher7/
├── input/                    # Put your photos here
│   ├── photos_20250730_103109/
│   ├── photos_20250730_103959/
│   └── ... (more sessions)
├── output/                   # Panoramas appear here
│   ├── pano_20250730_103109.tif
│   ├── pano_20250730_103959.tif
│   └── ... (more panoramas)
├── templates/
│   ├── project1.pto
│   └── project2.pto
├── quick-start.sh           # One-command solution
├── distribute_sessions.sh   # Parallel distributor
└── docker-compose.yml
```

## ⚙️ Configuration

### Number of Instances
```bash
# Use 2 instances (for smaller batches)
./distribute_sessions.sh ./input project1.pto 2

# Use 6 instances (if you have more CPU cores)
./distribute_sessions.sh ./input project1.pto 6
```

### Stitching Options
```bash
# High quality with light protection
./distribute_sessions.sh ./input project1.pto 4 --protect-lights --clip-thr=0.998

# No cropping (full panorama)
./distribute_sessions.sh ./input project1.pto 4 --no-crop

# Custom clipping settings
./distribute_sessions.sh ./input project1.pto 4 -- --clip-thr=0.999 --clip-pct=0.0001
```

## 🐳 Container Management

```bash
# Start containers
./docker-run.sh 4

# Check status
docker ps --filter "name=panorama_stitcher"

# View logs
docker logs panorama_stitcher_1

# Stop containers
./docker-stop.sh

# Access container shell for debugging
docker exec -it panorama_stitcher_1 bash
```


## 🔍 Troubleshooting

### Check Input
```bash
# Verify your photos are in the right place
find ./input -name "*.jpg" | head -10

# Count sessions
find ./input -maxdepth 1 -type d -name "photos_*" | wc -l
```

### Debug Containers
```bash
# Check if containers are running
docker ps | grep stitcher

# Test single session manually
docker exec panorama_stitcher_1 ./stitch.sh templates/project1.pto test_output /app/input/photos_20250730_103109
```

### Memory Issues
```bash
# Reduce parallel instances
./distribute_sessions.sh ./input project1.pto 2

# Or increase Docker memory limit in Docker Desktop
```

For your photo sessions:

```bash
# Copy your photos
cp -r ~/photos ./input/

# Process everything (takes ~6 minutes)
./quick-start.sh

# Results:
# ./output/pano_20250730_103109.tif
# ./output/pano_20250730_103959.tif
# ... (11 panoramas total)
```
