#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  disk_scan.sh  —  Disk Usage Report Generator
#  Usage:  bash disk_scan.sh [directory] [depth]
#          bash disk_scan.sh --whole-drive
#  Default: scans $HOME, depth 3
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_HTML="$SCRIPT_DIR/ReportTemplates/disk_report_template.html"

WHOLE_DRIVE=0
if [ "${1:-}" = "--whole-drive" ]; then
  WHOLE_DRIVE=1
  TARGET="/System/Volumes/Data"
  DISPLAY_TARGET="Whole Mac"
  DEPTH="all"
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: bash disk_scan.sh [directory] [depth]"
  echo "       bash disk_scan.sh --whole-drive"
  exit 0
else
  TARGET="${1:-$HOME}"
  DISPLAY_TARGET="$TARGET"
  DEPTH="${2:-3}"
fi

if [ "$WHOLE_DRIVE" -eq 0 ]; then
  case "$DEPTH" in
    ''|*[!0-9]*) echo "Error: depth must be a non-negative integer" >&2; exit 1 ;;
  esac
fi

if [ ! -d "$TARGET" ]; then
  echo "Error: not a directory: $TARGET" >&2
  exit 1
fi

echo "🔍 Scanning: $DISPLAY_TARGET ..."
if [ "$WHOLE_DRIVE" -eq 1 ]; then
  echo "   Collecting the complete directory tree; charts show a local depth window as you drill in."
  if [ -n "${2:-}" ]; then
    echo "   Note: the depth argument is no longer needed in whole-drive mode and was ignored."
  fi
else
  echo "   Detail depth: $DEPTH"
fi
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
DU_PID=""
cleanup() {
  if [ -n "$DU_PID" ] && kill -0 "$DU_PID" 2>/dev/null; then
    kill "$DU_PID" 2>/dev/null || true
  fi
  rm -f "$TMP" "$RAW_TMP" "$ERR_TMP"
}
trap cleanup EXIT

DU_COMMAND=(du)
if [ "$WHOLE_DRIVE" -eq 1 ] && [ "$EUID" -ne 0 ] && [ "${DISK_SCAN_NO_PROMPT:-0}" != "1" ] && [ -t 0 ]; then
  echo ""
  echo "   A whole-drive scan can use administrator access to read system-owned folders."
  echo "   macOS privacy-protected data also requires Full Disk Access for your terminal app."
  read -r -p "   Scan with administrator privileges? [Y/n] " answer
  case "$answer" in
    [nN]|[nN][oO]) ;;
    *)
      if sudo -v; then
        DU_COMMAND=(sudo du)
      else
        echo "   Administrator authentication failed." >&2
        exit 1
      fi
      ;;
  esac
fi

if [ "$WHOLE_DRIVE" -eq 1 ]; then
  "${DU_COMMAND[@]}" -x "$TARGET" > "$RAW_TMP" 2> "$ERR_TMP" &
else
  "${DU_COMMAND[@]}" -d "$DEPTH" -x "$TARGET" > "$RAW_TMP" 2> "$ERR_TMP" &
fi
DU_PID=$!

if [ -t 1 ]; then
  SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  FRAME=0
  FOLDER_COUNT=0
  SCAN_STARTED=$SECONDS
  while kill -0 "$DU_PID" 2>/dev/null; do
    if [ $(( FRAME % 8 )) -eq 0 ]; then
      FOLDER_COUNT=$(wc -l < "$RAW_TMP" | tr -d ' ')
    fi
    ELAPSED=$(( SECONDS - SCAN_STARTED ))
    printf '\r\033[K   %s Scanning... %02d:%02d elapsed · %s folders discovered' \
      "${SPINNER[$(( FRAME % ${#SPINNER[@]} ))]}" \
      $(( ELAPSED / 60 )) $(( ELAPSED % 60 )) "$FOLDER_COUNT"
    FRAME=$(( FRAME + 1 ))
    sleep 0.25
  done
fi

wait "$DU_PID"
DU_STATUS=$?
DU_PID=""

if [ -t 1 ]; then
  FOLDER_COUNT=$(wc -l < "$RAW_TMP" | tr -d ' ')
  ELAPSED=$(( SECONDS - SCAN_STARTED ))
  printf '\r\033[K   ✓ Scan complete · %02d:%02d elapsed · %s folders discovered\n' \
    $(( ELAPSED / 60 )) $(( ELAPSED % 60 )) "$FOLDER_COUNT"
fi

if [ "$DU_STATUS" -ne 0 ] && [ ! -s "$RAW_TMP" ]; then
  echo "Error: disk scan failed." >&2
  sed -n '1,3p' "$ERR_TMP" >&2
  exit "$DU_STATUS"
fi
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
RESULT_DATA="$RESULT_DIR/disk_data.json"

python3 - <<PYEOF
import os, json

tmp_file  = "$TMP"
target    = "$TARGET"
display_target = "$DISPLAY_TARGET"
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

# Build the complete tree in O(n). The previous recursive builder searched all
# rows for every node and truncated each directory to 50 children, which does
# not scale to Baobab-style full-depth scans.
nodes = {}
for row in rows:
    normalized_path = os.path.abspath(row["path"])
    nodes[normalized_path] = {
        "name":  row["name"],
        "rel":   row["rel"],
        "bytes": row["bytes"],
        "children": []
    }

for row in rows:
    if row["depth"] == 0:
        continue
    normalized_path = os.path.abspath(row["path"])
    parent_path = os.path.dirname(normalized_path)
    parent = nodes.get(parent_path)
    if parent is not None:
        parent["children"].append(nodes[normalized_path])

for node in nodes.values():
    node["children"].sort(key=lambda child: child["bytes"], reverse=True)

root_rows = [r for r in rows if r["depth"] == 0]
if not root_rows:
    root_rows = [rows[0]] if rows else []

root = nodes.get(os.path.abspath(root_rows[0]["path"])) if root_rows else None
if root is None:
    root = {"name": target, "rel": "/", "bytes": 0, "children": []}
if int("$WHOLE_DRIVE"):
    root["name"] = display_target

output = {
    "target": target,
    "display_target": display_target,
    "scope": "whole_drive" if int("$WHOLE_DRIVE") else "folder",
    "depth_mode": "all" if int("$WHOLE_DRIVE") else "limited",
    "requested_depth": None if int("$WHOLE_DRIVE") else int("$DEPTH"),
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
    "top_count": len(root["children"])
}

if output["permission_errors"]:
    with open(error_file, errors="replace") as errors:
        output["permission_error_samples"] = [
            line.strip() for line in errors
            if "Operation not permitted" in line or "Permission denied" in line
        ][:5]

def windowed_node(node, remaining_depth):
    has_children = bool(node["children"])
    include_children = remaining_depth > 0
    return {
        "name": node["name"],
        "rel": node["rel"],
        "bytes": node["bytes"],
        "has_children": has_children,
        "children_loaded": include_children or not has_children,
        "children": [windowed_node(child, remaining_depth - 1) for child in node["children"]]
                    if include_children else []
    }

# Keep the complete hierarchy beside the report for the loopback viewer. The
# HTML embeds only a local window so hundreds of thousands of nodes do not have
# to be parsed by the browser up front.
with open("$RESULT_DATA", "w") as data_file:
    json.dump(output, data_file, separators=(",", ":"))

initial_output = dict(output)
initial_output["tree"] = windowed_node(root, 6)
json_str = json.dumps(initial_output, separators=(",", ":"))

html = open("$OUT_HTML").read()
html = html.replace("__DISK_DATA_PLACEHOLDER__", json_str)

with open("$RESULT_HTML", "w") as f:
    f.write(html)

print(f"   Report written: $RESULT_HTML")
print(f"   Full tree index: $RESULT_DATA")
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
  --data "$RESULT_DATA" \
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
