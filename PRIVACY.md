# Privacy

DevMop runs entirely on your Mac.

- **No data leaves your Mac.** No analytics, telemetry, crash reporting, accounts or network requests.
- **What it reads:** folder and file sizes, names and dates, so it can show where space goes. It never opens the contents of your documents, mail or messages. File contents are read only to compare possible duplicates, and only on your Mac.
- **Why Full Disk Access:** macOS protects Library, Mail, Messages, Photos and the Trash. Without access DevMop can't measure them.
- **Tools it runs:** `git`, `xcrun simctl`, `docker`, `brew`, `pnpm`, `npm`, `tmutil`, `diskutil` and `qlmanage`, only to read information or to clean when you confirm.
- **What it stores:** your settings in `~/Library/Preferences/app.devmop.DevMop.plist`, and the last scan plus a history of cleanups in `~/Library/Application Support/DevMop`. Delete them any time.
