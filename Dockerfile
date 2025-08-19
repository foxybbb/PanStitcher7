# Simplified Dockerfile for local panorama stitching
FROM ubuntu:20.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install dependencies
RUN apt-get update && apt-get install -y \
    # Core utilities
    bash \
    coreutils \
    findutils \
    gawk \
    grep \
    sed \
    # Hugin panorama tools
    hugin-tools \
    # Essential blending tools
    enblend \
    enfuse \
    # ImageMagick for image processing
    imagemagick \
    # Cleanup
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure ImageMagick for large images
RUN sed -i 's/<policy domain="resource" name="memory" value="256MiB"\/>/<policy domain="resource" name="memory" value="2GiB"\/>/' /etc/ImageMagick-6/policy.xml \
    && sed -i 's/<policy domain="resource" name="map" value="512MiB"\/>/<policy domain="resource" name="map" value="4GiB"\/>/' /etc/ImageMagick-6/policy.xml \
    && sed -i 's/<policy domain="resource" name="disk" value="1GiB"\/>/<policy domain="resource" name="disk" value="8GiB"\/>/' /etc/ImageMagick-6/policy.xml

# Create application user
RUN useradd -m -s /bin/bash stitcher

# Set working directory
WORKDIR /app

# Copy only essential scripts
COPY stitch.sh /app/
COPY batch_stitch.sh /app/
COPY process_batch.sh /app/
COPY distribute_sessions.sh /app/

# Create necessary directories
RUN mkdir -p /app/input /app/output /app/templates /app/temp \
    && chown -R stitcher:stitcher /app

# Make scripts executable
RUN chmod +x /app/*.sh

# Switch to application user
USER stitcher

# Default command
CMD ["bash"]
