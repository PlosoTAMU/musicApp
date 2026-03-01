# Convert Xcode Archive to Sideloadable IPA (with Pre-signing Fix)

# Prerequisites:
# - Completed Xcode Archive (Product → Archive)
# - Homebrew installed
# - ldid installed: brew install ldid

# 1. Navigate to Your Latest Archive
ls -lt ~/Library/Developer/Xcode/Archives/
cd ~/Library/Developer/Xcode/Archives/YYYY-MM-DD/*.xcarchive/Products/Applications/

# 2. Copy App to Working Directory
cp -r Pulsor.app ~/Desktop/Pulsor_final.app
cd ~/Desktop

# 3. Remove All Existing Signatures
find Pulsor_final.app -name "_CodeSignature" -exec rm -rf {} \; 2>/dev/null
find Pulsor_final.app -name "embedded.mobileprovision" -delete
codesign --remove-signature Pulsor_final.app
codesign --remove-signature Pulsor_final.app/PlugIns/ShareToPulsor.appex

# 4. Pre-Sign with ldid (CRITICAL STEP - fixes SideStore ldid compatibility issue)
ldid -S Pulsor_final.app/PlugIns/ShareToPulsor.appex/ShareToPulsor
ldid -S Pulsor_final.app/Pulsor

# 5. Create the IPA
mkdir Payload
cp -r Pulsor_final.app Payload/
zip -ry Pulsor_final.ipa Payload
rm -rf Payload

# 6. Install in SideStore
# - Transfer Pulsor_final.ipa to your iPhone (AirDrop, Files app, etc.)
# - Open the IPA in SideStore
# - When prompted, select "Keep app extensions (use main profile)"
# - Wait for installation to complete

# Notes:
# - The pre-signing step (Step 4) is ESSENTIAL
# - SideStore's ldid has compatibility issues with unsigned extension binaries
# - If ldid outputs any errors during Step 4, DO NOT proceed to Step 5
# - Make sure you have fewer than 10 apps installed via free Apple ID