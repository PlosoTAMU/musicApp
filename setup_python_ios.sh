#!/bin/bash
# Setup script for embedding Python and yt-dlp in iOS app
# Run this from the musicApp directory

set -e

echo "🐍 Setting up Python for iOS..."

# Create directories
mkdir -p PythonFramework
mkdir -p PythonPackages

# Step 1: Download Python iOS framework from BeeWare
echo "📥 Downloading Python iOS framework..."
PYTHON_VERSION="3.11"
BEEWARE_VERSION="3.11-b1"

curl -L "https://github.com/beeware/Python-Apple-support/releases/download/${BEEWARE_VERSION}/Python-${PYTHON_VERSION}-iOS-support.${BEEWARE_VERSION}.tar.gz" \
    -o python-ios.tar.gz

echo "📦 Extracting Python framework..."
tar -xzf python-ios.tar.gz -C PythonFramework
rm python-ios.tar.gz

# Step 2: Download yt-dlp pure Python package
echo "📥 Downloading yt-dlp..."
pip download yt-dlp --no-deps --no-binary :all: -d ./PythonPackages

# Extract yt-dlp
cd PythonPackages
for f in *.tar.gz; do
    tar -xzf "$f"
    rm "$f"
done
for f in *.whl; do
    unzip -o "$f" -d .
    rm "$f"
done
cd ..

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps in Xcode:"
echo "1. Drag 'PythonFramework/Python.xcframework' into your Xcode project"
echo "2. Drag 'PythonFramework/python-stdlib' as a folder reference"
echo "3. Drag 'PythonPackages/yt_dlp' as a folder reference"
echo "4. In Build Settings, add Python.xcframework to 'Frameworks, Libraries, and Embedded Content'"
echo "5. Set 'Embed & Sign' for the framework"
echo ""
