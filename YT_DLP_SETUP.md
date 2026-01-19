# YouTube Audio Extraction with yt-dlp

## ✅ Setup Complete

Your app is now configured to use **yt-dlp** via Python.xcframework to extract MP3s from YouTube links!

## 📁 Required Directory Structure

Your Xcode project needs:

### 1. **Python.xcframework** (Linked Framework)
Already in your project! ✅
- This provides the Python runtime
- Linked in your target's **Frameworks and Libraries**

### 2. **python-group folder** (Bundle Resource)
Add this to your app bundle:

```
musicApp.app/
└── python-group/
    └── site-packages/
        └── yt_dlp/          # Your yt-dlp package here ✅
            ├── __init__.py
            ├── YoutubeDL.py
            └── ... (all yt-dlp files)
```

## 🔧 How to Add python-group to Your Project

### Step 1: Create the folder structure locally
```
your-project/
├── musicApp.xcodeproj
└── python-group/
    └── site-packages/
        └── yt_dlp/         # Copy your yt-dlp here
```

### Step 2: Add to Xcode
1. Drag `python-group` folder into Xcode project navigator
2. In the dialog:
   - ✅ Check "Copy items if needed"
   - ✅ Check "Create folder references" (Blue folder icon)
   - ✅ Select your target under "Add to targets"
3. Verify in **Build Phases** → **Copy Bundle Resources** that `python-group` appears

## 🎯 How It Works

### Python Setup
- **Python.xcframework** provides Python runtime (already linked)
- **python-group/site-packages** contains yt-dlp
- ShellManager sets `PYTHONPATH` to find yt-dlp
- No need for separate python-ios installation!

### Extraction Flow
```
User pastes YouTube URL
    ↓
YouTubeDownloader.downloadAudio()
    ↓
ShellManager.executeYTDLP()
    ↓
yt-dlp extracts video info
    ↓
Downloads audio stream
    ↓
Saves to "YouTube Downloads"
    ↓
Creates Track for playback ✅
```

### Option 2: Direct Download Method
If you want yt-dlp to handle the download directly (instead of streaming):

```swift
// In YouTubeDownloader.swift
let outputPath = "\(youtubeFolder)/%(title)s.mp3"
shellManager.downloadAudioDirectly(url: youtubeURL, outputPath: outputPath) { result in
    // Handle result
}
```

## 🚀 Features

✅ Extract audio from YouTube videos  
✅ Get video metadata (title, author, duration)  
✅ Stream audio URL for playback  
✅ Direct MP3 download with yt-dlp  
✅ Automatic file naming and organization  
✅ Error handling and user feedback  
✅ Uses Python.xcframework (no extra dependencies needed!)

## 🔍 Debugging

Check the console for these logs:
- `🐍 [Shell] Setting up Python environment...`
- `📍 [Shell] PYTHONPATH: .../python-group/site-packages`
- `✅ [Shell] Python initialized`
- `✅ [Shell] yt-dlp found and imported successfully`
- `� [Shell] yt-dlp version: ...`
- `�🔧 [Shell] Executing yt-dlp for URL: ...`
- `✅ [Shell] Extraction complete`

## ⚠️ Requirements

1. ✅ **Python.xcframework** linked to your target (you already have this!)
2. ✅ **PythonKit** framework linked
3. ⚠️ **python-group/site-packages/yt_dlp** folder added as bundle resource
4. ✅ Internet access permissions

## 📦 Where to Get yt-dlp

### Option 1: Download from GitHub
```bash
# On your Mac/PC
pip install yt-dlp --target ./python-group/site-packages
```

### Option 2: Clone from source
```bash
cd python-group/site-packages
git clone https://github.com/yt-dlp/yt-dlp.git yt_dlp
```

### Option 3: Download zip
1. Go to https://github.com/yt-dlp/yt-dlp
2. Download the `yt_dlp` folder
3. Place it in `python-group/site-packages/`

## 🎵 Output Format

Downloaded files are saved as:
```
Documents/YouTube Downloads/{clean_title}.m4a
```

## 💡 Quick Setup Checklist

- [ ] Python.xcframework linked in project (✅ you have this)
- [ ] PythonKit framework linked
- [ ] Created `python-group/site-packages/` folder structure
- [ ] Downloaded yt-dlp into `site-packages/yt_dlp/`
- [ ] Added `python-group` folder to Xcode as folder reference (blue icon)
- [ ] Verified `python-group` in Build Phases → Copy Bundle Resources
- [ ] Build and check console for `✅ [Shell] yt-dlp found and imported successfully`

---

**You only need Python.xcframework + python-group folder!**  
No python-ios or separate Python installation needed! 🎉
