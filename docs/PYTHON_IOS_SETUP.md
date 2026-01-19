# Embedding Python + yt-dlp in iOS App

This guide explains how to run Python and yt-dlp **entirely on your iPhone** without any external server.

## Quick Start

### Step 1: Download Python iOS Framework

BeeWare provides pre-compiled Python for iOS:

```bash
# On your Mac, in the musicApp directory:
cd /path/to/musicApp

# Download Python iOS support (about 50MB)
curl -L "https://github.com/beeware/Python-Apple-support/releases/download/3.11-b1/Python-3.11-iOS-support.b1.tar.gz" -o python-ios.tar.gz

# Extract
mkdir -p PythonFramework
tar -xzf python-ios.tar.gz -C PythonFramework
rm python-ios.tar.gz
```

You should now have:
- `PythonFramework/Python.xcframework/` - The Python interpreter
- `PythonFramework/python-stdlib/` - Python standard library

### Step 2: Download yt-dlp

```bash
# Download yt-dlp source
pip download yt-dlp --no-deps --no-binary :all: -d ./temp_packages

# Extract it
cd temp_packages
tar -xzf yt_dlp-*.tar.gz
cd ..

# Copy just the yt_dlp package folder
cp -r temp_packages/yt-dlp-*/yt_dlp ./PythonFramework/
rm -rf temp_packages
```

### Step 3: Add to Xcode Project

1. **Open your project in Xcode**

2. **Add Python.xcframework:**
   - Drag `PythonFramework/Python.xcframework` into your Xcode project navigator
   - Check "Copy items if needed"
   - Select your app target
   - In target settings > "Frameworks, Libraries, and Embedded Content"
   - Make sure Python.xcframework shows "Embed & Sign"

3. **Add python-stdlib:**
   - Drag `PythonFramework/python-stdlib` into Xcode
   - **IMPORTANT:** In the dialog, select "Create folder references" (blue folder icon)
   - This ensures the folder structure is preserved

4. **Add yt_dlp:**
   - Drag `PythonFramework/yt_dlp` into Xcode
   - Select "Create folder references" (blue folder icon)

5. **Verify Bundle Resources:**
   - Go to target > Build Phases > Copy Bundle Resources
   - Ensure `python-stdlib` and `yt_dlp` folders are listed

### Step 4: Create Bridging Header

Create a file `Python-Bridging-Header.h`:

```c
#ifndef Python_Bridging_Header_h
#define Python_Bridging_Header_h

#include <Python.h>

#endif
```

In Build Settings:
- Search for "Objective-C Bridging Header"
- Set it to: `$(SRCROOT)/musicApp/Python-Bridging-Header.h`

### Step 5: Configure Build Settings

In your target's Build Settings:

1. **Header Search Paths:** Add `$(SRCROOT)/PythonFramework/Python.xcframework/ios-arm64/Headers`

2. **Library Search Paths:** Add `$(SRCROOT)/PythonFramework/Python.xcframework/ios-arm64`

3. **Other Linker Flags:** Add `-lpython3.11`

### Step 6: Initialize Python in App

In your `musicAppApp.swift`:

```swift
import SwiftUI

@main
struct musicAppApp: App {
    init() {
        // Initialize Python when app launches
        EmbeddedPython.shared.initialize()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### Step 7: Use yt-dlp

```swift
// Download audio
Task {
    do {
        let (fileURL, title) = try await EmbeddedPython.shared.downloadAudio(url: youtubeURL)
        print("Downloaded: \(title) to \(fileURL)")
    } catch {
        print("Error: \(error)")
    }
}
```

## Troubleshooting

### "Python.h not found"
- Verify the bridging header path is correct
- Check Header Search Paths includes the Python headers

### "Library not found for -lpython3.11"
- Ensure Python.xcframework is properly embedded
- Check Library Search Paths

### App crashes on launch
- Python initialization may fail if paths are wrong
- Check Console.app for error messages
- Verify python-stdlib is a folder reference, not a group

### yt-dlp import fails
- Ensure yt_dlp folder is in Copy Bundle Resources
- Check it's a folder reference (blue folder icon)

## App Size Impact

Adding Python will increase your app size by approximately:
- Python.xcframework: ~15MB
- python-stdlib: ~30MB
- yt_dlp: ~5MB
- **Total: ~50MB additional**

## Alternative: Lighter Weight

If 50MB is too much, consider:

1. **Minimal Python stdlib** - Remove unused modules from python-stdlib
2. **yt-dlp standalone** - Use the single-file version of yt-dlp

## Notes

- No FFmpeg on iOS means audio format conversion isn't available
- yt-dlp will download the best available audio format directly
- Downloaded files will be in `.webm`, `.m4a`, or similar formats
- iOS can play most of these formats natively with AVFoundation
