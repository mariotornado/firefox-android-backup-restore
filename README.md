# Backup & restore of Firefox app data

This tutorial explains how one can create and restore a backup of the full
Android app data, fully offline.

While the Firefox app itself does not support `adb backup` due to
`allowBackups="false"` ([bug 1808763](https://bugzilla.mozilla.org/show_bug.cgi?id=1808763)),
we can still access all data by connecting through a Firefox-specific debugger.

Repository: https://github.com/Rob--W/firefox-android-backup-restore

This fork ([mariotornado/firefox-android-backup-restore](https://github.com/mariotornado/firefox-android-backup-restore))
adds a Windows GUI that automates the whole process below - see
[Windows GUI](#windows-gui-automated-no-manual-console-needed).

## Windows GUI (automated, no manual console needed)

This fork adds a Windows GUI application, `FirefoxTransferGui.exe`, that
fully automates the manual steps described in the rest of this README.
Instead of pasting [`snippets_for_firefox_debugging.js`](snippets_for_firefox_debugging.js)
into a Browser Toolbox console by hand, it speaks Firefox's DevTools
Remote Debugging Protocol directly over an adb-forwarded socket
(`localabstract:org.mozilla.firefox/firefox-debugger-socket`) to run the
same backup/restore logic in Firefox's Main Process - no `about:debugging`,
no copy-pasting, no manual `nc`/`adb push` steps.

Just run `FirefoxTransferGui.exe`:

- Pick your device from the auto-detected list.
- Click **Backup from device -> file** or **Restore from file -> device**.
- Watch progress in the live log pane.

### First-time setup wizard

If no device is ready yet, the app opens a **Setup Help** wizard that
walks through what's missing step by step, with live re-checks every
2 seconds:

1. Enabling Developer options and USB debugging on the phone.
2. Authorizing this computer's USB debugging request.
3. Installing Firefox, if it isn't already.
4. Enabling Firefox's own "Remote debugging via USB" toggle.

It detects which of these is still missing and shows only the relevant
instructions, turning green once the device is ready to use.

### Building it yourself

The GUI is plain PowerShell (`FirefoxTransferGui.ps1`, using
`FirefoxRdp.psm1` as the protocol client and `fab_rdp_payload.js` for the
on-device logic), compiled to a standalone `.exe` with
[ps2exe](https://github.com/MScholtes/PS2EXE):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe -inputFile FirefoxTransferGui.ps1 -outputFile FirefoxTransferGui.exe -noConsole -STA
```

`Invoke-FirefoxBackup.ps1` / `Invoke-FirefoxRestore.ps1` provide the same
automation as plain command-line scripts, if you'd rather not use the GUI.

---

*The GUI, DevTools protocol automation, and setup wizard in this fork were
built with [Claude Code](https://claude.com/claude-code).*

## Requirements

All you need is `adb`, and a desktop Firefox instance to use `about:debugging`:

- Tutorial with screenshots of using `about:debugging`: https://extensionworkshop.com/documentation/develop/developing-extensions-for-firefox-for-android/#debug-your-extension
- Documentation of `about:debugging`: https://firefox-source-docs.mozilla.org/devtools-user/about_colon_debugging/index.html#connecting-to-a-remote-device
- Optional, adb over Wi-Fi (instead of USB): https://firefox-source-docs.mozilla.org/devtools-user/about_colon_debugging/index.html#about-colon-debugging-connecting-to-android-over-wi-fi

## Relevant files

The data of Android apps are usually stored in internal storage, private to the
app, inaccessible to other apps and adb. External storage at `/sdcard/` can be
accessed through `adb`, but we need to use a special subdirectory to make sure
that the app can access it without requiring special storage permissions.

Examples of paths for Firefox (app ID `org.mozilla.firefox`):

- Private app data: `/data/user/0/org.mozilla.firefox/`
- Public directory: `/sdcard/Android/data/org.mozilla.firefox/`

The private app data directory contains several directories and files, the most
important ones being:

- `shared_prefs/` - Firefox UI settings and customizations.
- `files/` - Firefox profile directory, with website data (cookies etc).
- `databases/` - Tabs, collections, autofill, logins & passwords, and more.

The following are also relevant for consistency, but not critical:

- `cache/` - Caches, including thumbnails and favicons.
- `nimbus_data/` - Feature flags. Optional, but can change behavior.
- `no_backup/` - Includes `androidx.work` database, e.g. add-on update checks.
- `glean_data/` - Telemetry data (very old profiles may also have `telemetry/`).

## Backup

To backup, prepare to receive the backup data in the terminal:

```sh
adb reverse tcp:12101 tcp:12101
nc -l -s 127.0.0.1 -p 12101 > firefox-android-backup.tar.gz
```

Open the Firefox app on your phone, and visit `about:blank` (any webpage works).
Copy the contents of [`snippets_for_firefox_debugging.js`](snippets_for_firefox_debugging.js).
Open `about:debugging`, scroll down to "Main Process" and click on Inspect.
Switch to the Console, paste the code and run it. Then type and run:

```js
fab_backup_create();
```

This copies [relevant files](#relevant-files) to `firefox-android-backup.tar.gz`
without changing any data, except for one log file. To remove the log file, run:

```js
fab_cleanup();
```

## Restore

The steps below will replace [relevant files](#relevant-files) with the backup.

To restore the profile from the backup, put the backup archive on the device:

```sh
adb shell mkdir /sdcard/Android/data/org.mozilla.firefox/
adb push firefox-android-backup.tar.gz /sdcard/Android/data/org.mozilla.firefox/
```

Open the Firefox app on your phone, and visit `about:blank` (any webpage works).
Copy the contents of [`snippets_for_firefox_debugging.js`](snippets_for_firefox_debugging.js).
Open `about:debugging`, scroll down to "Main Process" and click on Inspect.
Switch to the Console, paste the code and run it.

Then type `fab_backup_restore();` and run it. This has no visible output, unless
an error occurs. Upon successful completion, the app is killed to prevent the
old app instance from corrupting the restored data. The logs can be viewed with:

```sh
adb shell cat /sdcard/Android/data/org.mozilla.firefox/firefox-android-backup.log
```

When you are done, remove the archive and log file with:

```js
fab_cleanup();
```
