copybara — Install Instructions
==============================

1. Drag "copybara.app" into the Applications folder.

2. Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/copybara.app

   (This is required because the app is not signed with an Apple
   Developer ID. Without it, macOS will refuse to open the app with
   a "could not verify copybara is free of malware" warning.)

3. Launch copybara from /Applications.

4. On first run, macOS will prompt for permissions. Grant both:
     - Accessibility       (System Settings → Privacy & Security)
     - Screen Recording    (System Settings → Privacy & Security)

   You may need to quit and relaunch the app after granting these.

Requirements: Apple Silicon Mac, macOS 14 or later.
