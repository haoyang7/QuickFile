# Install QuickFile

English · [简体中文](INSTALLATION.md) · [Back to QuickFile](README.md)

You only need to install QuickFile once. To add its **New File** menu to Finder, turn on its Finder extension after installation.

## 1. Download

Open the [release page](https://github.com/haoyang7/QuickFile/releases/tag/v0.1.0-beta.3) and download these two files from **Assets**:

- `QuickFile-v0.1.0-beta.3.dmg` — the app installer.
- `QuickFile-v0.1.0-beta.3.dmg.sha256` — a small file used to check the download.

The same installer works on Apple Silicon and Intel Macs. The minimum system is macOS 13. This is a Beta; see the release page for the systems and workflows actually tested.

### Check the download

Keep both files in the same folder. Open **Terminal**, type `cd` followed by a space, drag that folder into Terminal, then press Return. Paste this command and press Return:

```bash
shasum -a 256 -c QuickFile-v0.1.0-beta.3.dmg.sha256
```

If you see `OK`, continue. If it reports a mismatch, download both files again. This checks that the installer matches the published download; it is not an Apple security approval.

The other release attachments are optional: `INSTALL.txt` contains installation help; the two JSON files contain build and package-check records.

## 2. Put QuickFile in Applications

1. Open the `.dmg` file you downloaded.
2. Drag **QuickFile.app** onto **Applications** in that window.
3. Wait for copying to finish, then eject the QuickFile disk in Finder.
4. Open **Applications → QuickFile**.

Already have QuickFile? Back up your templates, saved folder access and old app, then quit the old version before replacing it. See [Updating or going back](#updating-or-going-back).

### If macOS stops the app from opening

This Community version has not been notarized by Apple. It uses an ad-hoc signature, which checks the app’s integrity but does not identify an Apple-verified developer.

After trying to open QuickFile, open **System Settings → Privacy & Security**. Find the message about QuickFile, click **Open Anyway**, and follow the prompts. Only approve the copy you downloaded from this project’s release page and checked above.

You do not need to turn off your Mac’s security protection or give QuickFile Full Disk Access. If you cannot find the approval option, [report the exact message](https://github.com/haoyang7/QuickFile/issues). See also [Apple’s opening instructions](https://support.apple.com/102445).

## 3. Make your first file

1. In QuickFile, open **Create File**.
2. Click **Choose Folder…** and choose a test folder.
3. Choose **Text Document**, then type `Meeting Notes` as the filename.
4. Click **Create File**, then **Show in Finder**.

You should see `Meeting Notes.txt`. If that name was already taken, the new file has a number added. QuickFile does not overwrite the old file.

Choosing a folder here is for this operation. It does not automatically save permission for Finder’s menu.

## 4. Add the Finder menu

1. Open QuickFile’s **Diagnostics** page and click **Manage Extensions…**.
2. In the system’s Finder extensions list, turn **QuickFile** on.
3. Click **Done**, return to QuickFile, and click **Refresh Status**.
4. Open your test folder in Finder. Right-click an empty space and choose **New File → Text Document**.
5. If QuickFile asks for folder access, choose that same folder and confirm. If you cancel, no file is created and no new access is saved.

On macOS 15 and later, the Finder extensions list is under **System Settings → General → Login Items & Extensions**. On older versions, search System Settings for “Extensions”; the location can differ.

You can also save folder access from **Diagnostics → Authorize Folder…** and remove it with **Manage Access…**. Once set up, you can quit QuickFile and keep using the Finder menu.

## Common questions

**The Finder menu is missing.** Check that QuickFile’s extension switch is on and you clicked **Done**. Then return to QuickFile and click **Refresh Status**. An installed extension still needs this switch turned on.

**QuickFile asks to use a folder.** Select the folder where you want to create the file. Enabling the Finder extension and allowing access to a folder are separate steps. Only allow access to folders you need.

**A saved folder no longer works.** Check whether the drive is connected and the folder is writable, then select the folder again to renew access. Renamed or moved volumes may need this step.

**The file was created, but Finder did not show it.** Look in the chosen folder before creating another copy.

**Templates will not load, or QuickFile reports a storage error.** Use the reload or repair action shown in the app. For damaged or missing settings, use the offered backup/default recovery. Do not delete the data folder to try to fix it. A repair of saved records does not grant access to a folder; that may still need your confirmation.

**It keeps asking to access data from other apps.** That is not an expected setup step for this version. Keep the message and describe what you clicked when [reporting the problem](https://github.com/haoyang7/QuickFile/issues).

**How do I check for updates?** The public v0.1.0-beta.3 (build 107) linked above includes **Check for Updates…**. Only a click requests the fixed repository’s GitHub Release API and validates the matching `build-provenance.json`; missing or mismatched receipts, network failures and rate limits are shown clearly. Tagged candidates are ordered by marketing version, Beta number and then the stable release of that version; builds are compared only for the same tag. Older packages without a tag keep the marketing-version/build comparison. The Beta preference is off by default, so only stable releases are checked; turn on **Receive beta versions** in Settings to include Beta releases. If a newer release is found, it provides a release page link; downloading, verifying and replacing the app remain manual. The earlier public v0.1.0-beta.2 (build 98) did not include this action. Community has no Sparkle and never downloads or installs updates automatically.

## Updating or going back

Before replacing an existing copy:

1. In **Templates → More**, export your templates.
2. Keep a copy of the old app and back up QuickFile’s data folder, which also contains saved folder access. Template export alone does not include that access. You can locate the data folder through the app’s storage-maintenance controls. Its location is `~/Library/Application Support/QuickFileCommunity/`.
3. Quit QuickFile, then install the new version using the steps above.
4. Check your templates and create a file in a test folder, both from the app and from Finder. If folder access no longer works, select that folder again.

Versions using the current shared storage keep templates and settings in the same place. Switching signing methods can require fresh folder approval. Much older App Group builds require you to export templates in the old app and import them in the new app; their settings and folder access do not automatically move across.

If you need to go back, quit the new app and restore the old app you kept. Keep the current data and any recovery files. Recheck templates, folder access and Finder creation: replacing the app alone does not restore earlier data or system permissions. If problems continue, stop replacing files and report what happened.

An old Finder extension can remain running after an update. Save your work before relaunching Finder, then check the menu again.

## Get help

[Open a GitHub issue](https://github.com/haoyang7/QuickFile/issues) and include your macOS version, Mac chip, QuickFile version, the steps you took and the message you saw. **Diagnostics → Copy Diagnostic Summary** provides a summary without template contents or folder bookmarks. Remove personal information from screenshots and logs before sharing them.

## Advanced troubleshooting

Most users should use the steps above. The [technical installation reference](INSTALLATION.md#技术排障参考) is available in Simplified Chinese and covers quarantine attributes, storage recovery and signing differences. Removing a quarantine attribute does not sign the app, grant folder access or prove that installation works with default security settings.
