# DiskScanHelpers

> Disk cleanup helpers for Xcode users — find what's eating your storage and clean it up safely.

Xcode caches (DerivedData, simulators, archives, device support) can quietly grow to dozens of gigabytes. These two small macOS scripts help you see exactly what's taking space and clean it up — with interactive HTML reports you open in your browser.

No dependencies beyond what ships with macOS (`bash`, `du`, `python3`).

![DiskScanHelpers — Xcode cleanup and disk usage reports side by side](docs/screenshots/hero.png)

---

## Project structure

```
DiskScanHelpers/
├── disk_scan.sh                 # General disk usage scanner
├── xcode_disk_scan.sh           # Xcode-specific scanner
└── ReportTemplates/
    ├── disk_report_template.html
    └── xcode_report_template.html

/tmp/DiskScanReports/            # Generated reports — cleared on reboot
├── disk_report.html
└── xcode_report.html
```

---

## xcode_disk_scan — Xcode Disk Scan

Scans Xcode-related cache/data folders, prints sizes, and suggests cleanup actions split by **safety tier**.

### Usage

```bash
bash xcode_disk_scan.sh
```

Opens `/tmp/DiskScanReports/xcode_report.html` automatically.

### What it shows

- **DerivedData** — build caches per project, sorted by size
- **DeviceSupport** — debug symbols per iOS/watchOS/tvOS version
- **Simulators** — devices with name, runtime, size, status; orphaned devices flagged
- **Runtimes** — CoreSimulator runtime images
- **Archives** — shipped builds with app name, date, size; supports custom archive locations
- **Caches** — Xcode app cache, SwiftPM caches (system + user), Interface Builder cache
- Tiered summary: **Safe to delete** vs **Needs review** with separate totals
- Recommended commands grouped by safety tier

### Safety tiers

**✅ Safe tier (run anytime):**
- **DerivedData** — fully safe. Xcode rebuilds on next project open.
- **DeviceSupport** — safe. Xcode re-downloads on next device connect.
- **Orphan simulators** — `xcrun simctl delete unavailable` is always safe.
- **Caches** — regenerated on use.

**⚠️ Review tier (read notes first):**
- **Runtimes** — remove via Xcode → Settings → Platforms. Don't delete files directly.
- **Archives** — manage via Xcode → Organizer. Keep the latest per shipped version (dSYMs for crash symbolication).

Read-only — **nothing is deleted unless you copy a command and run it yourself.**

![Xcode cleanup report — safety-tier actions](docs/screenshots/xcode-report.png)

---

## disk_scan — General Disk Usage Report

Visual disk usage analyzer that generates an interactive HTML report for any folder. Useful for hunting storage hogs outside Xcode too.

### Usage

```bash
bash disk_scan.sh [directory] [depth]
bash disk_scan.sh --whole-drive [depth]
```

- **directory** — path to scan (default: `$HOME`)
- **depth** — how many levels deep (default: `3`)
- **--whole-drive** — scans the writable macOS data volume and reports overall disk capacity, usage, and available space

Examples:
```bash
bash disk_scan.sh                          # scan $HOME, depth 3
bash disk_scan.sh ~ 4                      # scan $HOME, depth 4 (more detail)
bash disk_scan.sh /Users/me/Projects 2     # scan specific folder, depth 2
bash disk_scan.sh --whole-drive 4          # scan the whole Mac data volume
```

Whole-drive mode offers to run `du` with administrator privileges. For privacy-protected folders such as Mail, Messages, and Photos, macOS may also require you to grant Full Disk Access to your terminal app in **System Settings → Privacy & Security → Full Disk Access**. User-data permission failures are reported separately from macOS system Data Vault paths, which can remain unreadable even with Full Disk Access.

### How it works

1. Runs `du` to collect directory sizes
2. Embedded Python builds a tree structure from the `du` output
3. Injects the JSON data into the HTML template
4. Saves the result to `/tmp/DiskScanReports/disk_report.html`
5. Opens it through a token-protected server bound to `127.0.0.1`, enabling **Open in Finder** buttons for scanned folders

The template is never modified — data is injected into a copy. Re-running the script overwrites the previous result.

### Visualization

Three switchable views (canvas-based):

- **Sunburst** — concentric rings with percentage labels; inner = top-level, outer = deeper levels
- **Partition** — columnar layout showing parent→child hierarchy with colored backgrounds and separator lines
- **BoxMap** — nested treemap with proportional rectangles

![Sunburst view](docs/screenshots/disk-sunburst.png)
![Partition view](docs/screenshots/disk-partition.png)
![BoxMap (treemap) view](docs/screenshots/disk-boxmap.png)

All views support:
- Click to drill into a folder, breadcrumb / back to navigate up
- Hover tooltip with name, path, size, and percentage
- See the full active path beside **Open in Finder**; leaf blocks open directly, while parent blocks drill down and update the path
- Open the current folder or any folder-table row directly in Finder
- Interactive stacked bar and legend (click to drill in)

Sidebar:
- Sortable folder table with size bars
- Search/filter with "Only Top Folders" toggle (unchecked = search all levels)
- Click any row to drill into that folder

---

## Installation

Clone the repo and run the script you need — no install steps, no dependencies to download:

```bash
git clone https://github.com/Dimajp/DiskScanHelpers.git
cd DiskScanHelpers
bash xcode_disk_scan.sh   # or disk_scan.sh
```

## Requirements

- macOS (uses `du -d` flag and Xcode-specific paths)
- `python3` (ships with modern macOS)
- A browser to view the report

## Output

Each script generates a self-contained HTML file under `/tmp/DiskScanReports/`. The report opens automatically in your default browser, and `/tmp/` is cleared on system reboot — so old reports don't pile up.

---

## License

Released under the **MIT License**. See the [LICENSE](LICENSE) file for details.

Copyright © 2026 Dmitry Protopopov (github.com/Dimajp).
