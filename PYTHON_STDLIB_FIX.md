# Fix: Failed to Import Encodings Module

## 🔴 Error:
```
Fatal Python error: failed to import encodings module
```

## 📋 Root Cause
Python.xcframework needs access to the Python **standard library** (encodings, sys, os, etc.). The framework contains these files, but we need to tell Python where to find them.

## 🔍 Where is the Python Standard Library?

The standard library is inside `Python.xcframework`. Check these locations:

```
Python.xcframework/
├── ios-arm64/
│   └── Python.framework/
│       ├── lib/
│       │   └── python3.11/     ← Standard library here!
│       │       ├── encodings/
│       │       ├── collections/
│       │       ├── os.py
│       │       └── ... (all stdlib modules)
│       └── Python (binary)
```

## ✅ Solution 1: Add Python Standard Library to Bundle

### Option A: Copy from Python.xcframework
1. Navigate to your `Python.xcframework`
2. Find: `Python.framework/lib/python3.X/` (where X is your version)
3. Copy the entire `lib` folder
4. Add it to your Xcode project:
   - Create a folder structure: `python-stdlib/lib/python3.11/`
   - Paste all the standard library files there
   - Add to Xcode as **folder reference** (blue folder)

### Option B: Bundle Python.framework/lib
1. In Xcode Build Phases → **Embed Frameworks**
2. Make sure `Python.framework` is set to **"Embed & Sign"** or **"Embed Without Signing"**
3. This should copy the framework's lib directory to your app bundle

## ✅ Solution 2: Set PYTHONHOME Correctly

The updated `ShellManager` now tries to find the Python standard library automatically, but you may need to verify:

### Check Console Logs:
```
📍 [Shell] Python framework path: .../Python.framework
📍 [Shell] Python lib path: .../Python.framework/lib
📍 [Shell] PYTHONHOME: .../Python.framework
```

If you see empty paths, the framework structure is different than expected.

## 🔧 Manual Configuration

If automatic detection fails, you can hardcode the paths:

```swift
// In setupPython()
let pythonHome = "\(bundlePath)/Frameworks/Python.framework/Versions/3.11"
let pythonLib = "\(pythonHome)/lib/python3.11"

setenv("PYTHONHOME", pythonHome, 1)
setenv("PYTHONPATH", "\(pythonLib):\(sitePackagesPath)", 1)
```

## 📦 Required Directory Structure

Your app bundle should contain:

```
musicApp.app/
├── Frameworks/
│   └── Python.framework/
│       └── lib/
│           └── python3.X/
│               ├── encodings/      ← This fixes the error!
│               ├── collections/
│               ├── os.py
│               └── ... (all stdlib)
│
└── python-group/
    └── site-packages/
        └── yt_dlp/
```

## 🎯 Quick Checklist

- [ ] Python.xcframework is properly embedded in Frameworks
- [ ] `lib/python3.X` directory exists in Python.framework
- [ ] `encodings` module exists in `lib/python3.X/encodings/`
- [ ] PYTHONHOME environment variable is set
- [ ] PYTHONPATH includes the standard library path
- [ ] Console shows successful Python initialization

## 🔍 Debugging

Run your app and check the console for:
```
📍 [Shell] Python lib path: /path/to/Python.framework/lib
📍 [Shell] Found Python lib: .../python3.11
📍 [Shell] PYTHONHOME: /path/to/Python.framework
📍 [Shell] PYTHONPATH: .../python3.11:.../site-packages
✅ [Shell] Python initialized
```

If you see empty paths, Python.framework isn't in the expected location.

## 💡 Alternative: Use Python-Apple-support

If Python.xcframework doesn't include the standard library:

1. Download Python-Apple-support from: https://github.com/beeware/Python-Apple-support
2. This includes Python with the full standard library pre-configured
3. Replace your Python.xcframework with their version

---

The updated `ShellManager.swift` now attempts to auto-detect the Python standard library location. Check console logs to verify! 🚀
