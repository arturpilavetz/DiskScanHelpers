#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  disk_scan.sh  —  Disk Usage Report Generator
#  Usage:  bash disk_scan.sh [directory] [depth]
#          bash disk_scan.sh --whole-drive [depth]
#  Default: scans $HOME, depth 3
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_HTML="$SCRIPT_DIR/ReportTemplates/disk_report_template.html"

WHOLE_DRIVE=0
if [ "${1:-}" = "--whole-drive" ]; then
  WHOLE_DRIVE=1
  TARGET="/System/Volumes/Data"
  DISPLAY_TARGET="Whole Mac"
  DEPTH="${2:-4}"
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: bash disk_scan.sh [directory] [depth]"
  echo "       bash disk_scan.sh --whole-drive [depth]"
  exit 0
else
  TARGET="${1:-$HOME}"
  DISPLAY_TARGET="$TARGET"
  DEPTH="${2:-3}"
fi

if [ ! -d "$TARGET" ]; then
  echo "Error: not a directory: $TARGET" >&2
  exit 1
fi

echo "🔍 Scanning: $DISPLAY_TARGET (depth $DEPTH) ..."
echo "   This may take a moment..."

# ── Helper: bytes → human readable
human() {
  local b=$1
  if   [ "$b" -ge 1000000000 ]; then printf "%.1f GB" "$(echo "$b 1000000000" | awk '{printf "%.1f", $1/$2}')";
  elif [ "$b" -ge 1000000 ];    then printf "%.1f MB" "$(echo "$b 1000000"    | awk '{printf "%.1f", $1/$2}')";
  elif [ "$b" -ge 1000 ];       then printf "%.1f KB" "$(echo "$b 1000"       | awk '{printf "%.1f", $1/$2}')";
  else printf "%d B" "$b"; fi
}

# ── Collect du data (512-byte blocks on macOS → multiply by 512)
# Exclude Time Machine / network mounts to keep it fast
TMP=$(mktemp)
RAW_TMP=$(mktemp)
ERR_TMP=$(mktemp)
cleanup() { rm -f "$TMP" "$RAW_TMP" "$ERR_TMP"; }
trap cleanup EXIT

DU_COMMAND=(du)
if [ "$WHOLE_DRIVE" -eq 1 ] && [ "$EUID" -ne 0 ] && [ "${DISK_SCAN_NO_PROMPT:-0}" != "1" ] && [ -t 0 ]; then
  echo ""
  echo "   A whole-drive scan can use administrator access to read system-owned folders."
  echo "   macOS privacy-protected data also requires Full Disk Access for your terminal app."
  read -r -p "   Scan with administrator privileges? [Y/n] " answer
  case "$answer" in
    [nN]|[nN][oO]) ;;
    *) DU_COMMAND=(sudo du) ;;
  esac
fi

"${DU_COMMAND[@]}" -d "$DEPTH" -x "$TARGET" > "$RAW_TMP" 2> "$ERR_TMP"
sort -rn "$RAW_TMP" > "$TMP"

PERMISSION_ERRORS=$(awk '/Operation not permitted|Permission denied/ { count++ } END { print count + 0 }' "$ERR_TMP")
if [ "$WHOLE_DRIVE" -eq 1 ]; then
  USER_PERMISSION_ERRORS=$(awk '/Operation not permitted|Permission denied/ && /\/Users\// { count++ } END { print count + 0 }' "$ERR_TMP")
  SYSTEM_PERMISSION_ERRORS=$(( PERMISSION_ERRORS - USER_PERMISSION_ERRORS ))
  SCAN_PERMISSION_ERRORS=0
else
  USER_PERMISSION_ERRORS=0
  SYSTEM_PERMISSION_ERRORS=0
  SCAN_PERMISSION_ERRORS=$PERMISSION_ERRORS
fi

if [ "$SCAN_PERMISSION_ERRORS" -gt 0 ]; then
  echo "   ⚠️  $SCAN_PERMISSION_ERRORS folders in the selected location could not be read."
fi
if [ "$USER_PERMISSION_ERRORS" -gt 0 ]; then
  echo "   ⚠️  $USER_PERMISSION_ERRORS user-data folders could not be read."
  echo "      Check Full Disk Access for your terminal app and restart the app after enabling it."
fi
if [ "$SYSTEM_PERMISSION_ERRORS" -gt 0 ]; then
  echo "   ℹ️  $SYSTEM_PERMISSION_ERRORS macOS-protected system folders were skipped."
  echo "      Some Data Vault paths remain unreadable even with Full Disk Access."
fi

TOTAL_BLOCKS=$(head -1 "$TMP" | awk '{print $1}')
TOTAL_BLOCKS=${TOTAL_BLOCKS:-0}
TOTAL_BYTES=$(( TOTAL_BLOCKS * 512 ))

# df reports 1024-byte blocks on macOS. These values describe the volume,
# while TOTAL_BYTES describes only the selected scan root.
read -r DISK_TOTAL_K DISK_USED_K DISK_AVAILABLE_K <<EOF
$(df -k "$TARGET" | tail -1 | awk '{print $2, $3, $4}')
EOF
DISK_TOTAL_BYTES=$(( DISK_TOTAL_K * 1024 ))
DISK_USED_BYTES=$(( DISK_USED_K * 1024 ))
DISK_AVAILABLE_BYTES=$(( DISK_AVAILABLE_K * 1024 ))

echo "   Scanned: $(human $TOTAL_BYTES)"
echo "   Disk: $(human $DISK_USED_BYTES) used · $(human $DISK_AVAILABLE_BYTES) available"

# ── Build data and inject into HTML template → /tmp/DiskScanReports/
RESULT_DIR="${DISK_SCAN_RESULT_DIR:-/tmp/DiskScanReports}"
mkdir -p "$RESULT_DIR"
RESULT_HTML="$RESULT_DIR/disk_report.html"

python3 - <<PYEOF
import os, json

tmp_file  = "$TMP"
target    = "$TARGET"
display_target = "$DISPLAY_TARGET"
depth_max = int("$DEPTH")
error_file = "$ERR_TMP"

rows = []
with open(tmp_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        blocks, path = int(parts[0]), parts[1]
        size_bytes = blocks * 512
        rel = os.path.relpath(path, target)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        rows.append({
            "path": path,
            "rel":  rel if rel != "." else "/",
            "name": os.path.basename(path) if rel != "." else os.path.basename(target),
            "bytes": size_bytes,
            "depth": depth
        })

rows.sort(key=lambda r: r["bytes"], reverse=True)

def build_node(row, all_rows):
    path = row["path"]
    depth = row["depth"]
    children = [
        r for r in all_rows
        if r["depth"] == depth + 1 and r["path"].startswith(path + "/")
    ]
    children.sort(key=lambda r: r["bytes"], reverse=True)
    return {
        "name":  row["name"],
        "rel":   row["rel"],
        "bytes": row["bytes"],
        "children": [build_node(c, all_rows) for c in children[:50]]
    }

root_rows = [r for r in rows if r["depth"] == 0]
if not root_rows:
    root_rows = [rows[0]] if rows else []

root = build_node(root_rows[0], rows) if root_rows else {"name": target, "rel": "/", "bytes": 0, "children": []}
if int("$WHOLE_DRIVE"):
    root["name"] = display_target
top = [r for r in rows if r["depth"] == 1][:100]

output = {
    "target": target,
    "display_target": display_target,
    "scope": "whole_drive" if int("$WHOLE_DRIVE") else "folder",
    "total_bytes": root_rows[0]["bytes"] if root_rows else 0,
    "disk": {
        "capacity_bytes": int("$DISK_TOTAL_BYTES"),
        "used_bytes": int("$DISK_USED_BYTES"),
        "available_bytes": int("$DISK_AVAILABLE_BYTES")
    },
    "permission_errors": int("$PERMISSION_ERRORS"),
    "scan_permission_errors": int("$SCAN_PERMISSION_ERRORS"),
    "user_permission_errors": int("$USER_PERMISSION_ERRORS"),
    "system_permission_errors": int("$SYSTEM_PERMISSION_ERRORS"),
    "tree": root,
    "top": top
}

if output["permission_errors"]:
    with open(error_file, errors="replace") as errors:
        output["permission_error_samples"] = [
            line.strip() for line in errors
            if "Operation not permitted" in line or "Permission denied" in line
        ][:5]

json_str = json.dumps(output)

html = open("$OUT_HTML").read()
html = html.replace("__DISK_DATA_PLACEHOLDER__", json_str)

with open("$RESULT_HTML", "w") as f:
    f.write(html)

print(f"   Report written: $RESULT_HTML")
PYEOF

echo ""
echo "✅ Done!"

if [ "${DISK_SCAN_NO_OPEN:-0}" = "1" ]; then
  exit 0
fi

# Serve on loopback so the report can ask Finder to open a selected folder.
SERVER_SCRIPT="$SCRIPT_DIR/report_server.py"
URL_FILE="$RESULT_DIR/report_url"
PID_FILE="$RESULT_DIR/report_server.pid"
LOG_FILE="$RESULT_DIR/report_server.log"

if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_COMMAND=$(ps -p "$OLD_PID" -o command= 2>/dev/null)
    case "$OLD_COMMAND" in
      *report_server.py*) kill "$OLD_PID" 2>/dev/null ;;
    esac
  fi
fi

rm -f "$URL_FILE"
TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
nohup python3 "$SERVER_SCRIPT" \
  --report "$RESULT_HTML" \
  --root "$TARGET" \
  --token "$TOKEN" \
  --url-file "$URL_FILE" \
  --pid-file "$PID_FILE" > "$LOG_FILE" 2>&1 &

for _ in {1..50}; do
  [ -s "$URL_FILE" ] && break
  sleep 0.05
done

if [ -s "$URL_FILE" ]; then
  REPORT_URL=$(cat "$URL_FILE")
  echo "   Opening interactive report..."
  open "$REPORT_URL"
else
  echo "   Could not start the interactive viewer; opening the static report."
  open "$RESULT_HTML"
fi
