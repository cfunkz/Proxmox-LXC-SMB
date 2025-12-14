#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# NAS Manager (Proxmox host) — STATE-DRIVEN
#
# Commands:
#   info      : layout, users, quotas (from /etc/nas/state.env)
#   smb       : backup | list | restore [file]
#   snapshot  : create | list | rollback <tag> | remove <tag>
#
# Version: 2025-12-14
# ==============================================================================

# ---------------- UI -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[1;33m'; NC='\033[0m'
say(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YEL}$*${NC}"; }
die(){ echo -e "${RED}Error: $*${NC}" >&2; exit 1; }

# ---------------- Preconditions -----------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root on Proxmox host."
command -v pct >/dev/null || die "pct not found."
command -v zfs >/dev/null || die "zfs not found."

# ---------------- Args ---------------------------------------------------------
[[ $# -ge 2 ]] || die "Usage: $0 <CTID> {info|smb|snapshot}"
CTID="$1"; CMD="$2"; shift 2
CONF="/etc/pve/lxc/${CTID}.conf"
pct status "$CTID" >/dev/null || die "CT $CTID not found."
[[ -f "$CONF" ]] || die "Missing CT config."

# ---------------- Globals ------------------------------------------------------
STATE_FILE="/etc/nas/state.env"
SMB_CONF="/etc/samba/smb.conf"
SMB_BACKUP="/etc/samba/backup"
SNAP_PREFIX="nas"

# State vars (loaded)
MODE=""
BASE=""
MP_IN=""
CREATE_SHARED=0
CREATE_PUBLIC=0
CREATE_GUEST=0
WORKGROUP=""
ALLOWED_SUBNETS=""
ENABLE_HOMES_RECYCLE=0

# ---------------- Helpers ------------------------------------------------------
ct(){ pct exec "$CTID" -- bash -lc "$*"; return 0; }

nas_users(){
  ct "getent group nas_users | awk -F: '{print \$4}'" | tr ',' '\n'
  return 0
}

# ---------------- State --------------------------------------------------------
load_state(){
  ct "[[ -f '$STATE_FILE' ]]" || die "NAS not installed (missing $STATE_FILE)."

  local env
  env="$(ct "cat '$STATE_FILE'")"
  eval "$env"

  [[ -n "${BASE_DATASET:-}" ]] || die "Invalid state.env (BASE_DATASET missing)"
  BASE="$BASE_DATASET"
  MODE="${MODE:-1}"
  MP_IN="${MP_IN:-/srv/nas}"
  CREATE_SHARED="${CREATE_SHARED:-0}"
  CREATE_PUBLIC="${CREATE_PUBLIC:-0}"
  CREATE_GUEST="${CREATE_GUEST:-0}"
  WORKGROUP="${WORKGROUP:-WORKGROUP}"
  ALLOWED_SUBNETS="${ALLOWED_SUBNETS:-}"
  ENABLE_HOMES_RECYCLE="${ENABLE_HOMES_RECYCLE:-0}"
}

# ---------------- Dataset Enumeration -----------------------------------------
nas_datasets(){
  echo "$BASE"

  if [[ "$MODE" == "2" ]]; then
    echo "${BASE}/homes"
    [[ $CREATE_SHARED -eq 1 ]] && echo "${BASE}/Shared"
    [[ $CREATE_PUBLIC -eq 1 ]] && echo "${BASE}/Public"
    [[ $CREATE_GUEST  -eq 1 ]] && echo "${BASE}/Guest"

    nas_users | while read -r u; do
      [[ -n "$u" ]] && echo "${BASE}/homes/${u}"
    done
  fi
}

# ---------------- Recycle Bin Cleanup ------------------------------------------
find_homes_user_recycle_bins(){
  load_state
  local p r
  p="$(ct "awk 'BEGIN{i=0} /^[[:space:]]*\\[homes\\]$/{i=1;next} i&&/^\\[/{exit} i&&/^\\s*path\\s*=/{sub(/^[^=]*=/,\"\");print;exit}' '$SMB_CONF'")"
  [[ -n "$p" ]] || p="$(ct "[[ -d '$MP_IN/homes' ]] && echo '$MP_IN/homes' || echo '$MP_IN'")"
  r="${p//%U/}"; r="${r%/}"
  ct "find '$r' -type d -path '*/.recycle/*' 2>/dev/null"
}

parse_timer(){
  local t="$1"
  case "$t" in
    *m) echo "*/${t%m} * * * *" ;;
    *h) echo "0 */${t%h} * * *" ;;
    *d) echo "0 0 */${t%d} *" ;;
    *) die "Invalid timer format (use Nm|Nh|Nd)" ;;
  esac
}

# ---------------- INFO ---------------------------------------------------------
cmd_info(){
  load_state

  local IP
  IP="$(ct "hostname -I 2>/dev/null | awk '{print \$1}'")" || IP="unknown"

  say "==================== NAS INFORMATION ===================="
  echo

  echo "Container:"
  echo "  CTID            : $CTID"
  echo "  IP address      : ${IP:-unknown}"
  echo

  echo "NAS design:"
  echo "  Base dataset    : $BASE"
  echo "  Base mount (CT) : $MP_IN"
  echo "  Mode            : $MODE"
  [[ "$MODE" == "1" ]] \
    && echo "  Layout          : single dataset with subdirectories" \
    || echo "  Layout          : per-user datasets + optional share datasets"
  echo

  echo "Shares:"
  echo "  Homes           : enabled (always)"
  echo "  Shared          : $([[ $CREATE_SHARED -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Public          : $([[ $CREATE_PUBLIC -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Guest           : $([[ $CREATE_GUEST  -eq 1 ]] && echo enabled || echo disabled)"
  echo

  echo "Datasets (usage / quota):"
  printf "  %-45s %-10s %-10s\n" "DATASET" "USED" "QUOTA"
  nas_datasets | while read -r ds; do
    [[ -z "$ds" ]] && continue
    printf "  %-45s %-10s %-10s\n" \
      "$ds" \
      "$(zfs get -H -o value used "$ds" 2>/dev/null || echo '-') " \
      "$(zfs get -H -o value quota "$ds" 2>/dev/null || echo '-')"
  done
  echo

  echo "Users (nas_users):"
  if ! nas_users | grep -q .; then
    echo "  (none)"
  else
    nas_users | while read -r u; do
      [[ -n "$u" ]] && echo "  - $u"
    done
  fi
  echo

  echo "Samba:"
  echo "  Workgroup       : $WORKGROUP"
  echo "  Recycle bin     : $([[ $ENABLE_HOMES_RECYCLE -eq 1 ]] && echo enabled || echo disabled)"
  echo "  Active shares   :"
  ct "awk '/^\[/{print \"    \"\$0}' '$SMB_CONF'" || echo "    (none)"
  echo

  echo "Network paths:"
  echo "  Homes  : \\\\${IP}\\<username>"
  [[ $CREATE_SHARED -eq 1 ]] && echo "  Shared : \\\\${IP}\\Shared"
  [[ $CREATE_PUBLIC -eq 1 ]] && echo "  Public : \\\\${IP}\\Public"
  [[ $CREATE_GUEST  -eq 1 ]] && echo "  Guest  : \\\\${IP}\\Guest"
  echo

  say "==================== END OF INFO ===================="
}

# ---------------- SMB ----------------------------------------------------------
cmd_smb(){
  local sub="${1:-}"
  case "$sub" in
    backup)
      ct "mkdir -p '$SMB_BACKUP'"
      local f="$SMB_BACKUP/smb.conf.$(date +%F-%H%M%S)"
      ct "cp '$SMB_CONF' '$f'"
      say "Saved $f"
      ;;
    list)
      ct "ls -1 $SMB_BACKUP 2>/dev/null || echo '(none)'"
      ;;
    restore)
      local f="${2:-}"
      [[ -z "$f" ]] && f="$(ct "ls -1t $SMB_BACKUP | head -n1")"
      ct "cp '$SMB_BACKUP/$f' '$SMB_CONF'"
      ct "testparm -s"
      say "Restored $f"
      ;;
    *) die "Usage: smb {backup|list|restore [file]}" ;;
  esac
}

# ---------------- SNAPSHOTS ----------------------------------------------------
cmd_snapshot(){
  load_state
  local sub="${1:-}" tag="${2:-}"

  case "$sub" in
    create)
      tag="${SNAP_PREFIX}-$(date +%F-%H%M%S)"
      nas_datasets | while read -r ds; do
        [[ -n "$ds" ]] && zfs snapshot "$ds@$tag"
      done
      say "Snapshot @$tag created"
      ;;
    list)
      zfs list -t snapshot | grep "@$SNAP_PREFIX-" || echo "(none)"
      ;;
    rollback)
      [[ -n "$tag" ]] || die "Specify tag"
      nas_datasets | while read -r ds; do
        zfs rollback -r "$ds@$tag"
      done
      ;;
    remove)
      [[ -n "$tag" ]] || die "Specify tag"
      nas_datasets | while read -r ds; do
        zfs destroy "$ds@$tag" 2>/dev/null || true
      done
      ;;
    *) die "snapshot {create|list|rollback <tag>|remove <tag>}" ;;
  esac
}

# ---------------- RECYCLE BIN CLEANUP -----------------------------------------
cmd_recycle(){
  local sub="${1:-}"

  case "$sub" in
    timer)
      local timer="${2:-}"
      [[ -n "$timer" ]] || die "Usage: recycle timer <Nm|Nh|Nd|off>"

      # ---------------- OFF ----------------
      if [[ "$timer" == "off" ]]; then
        say "Disabling recycle flush cron in CT $CTID"
        ct "rm -f /etc/cron.d/nas-recycle /root/nas-recycle-cron.sh"
        say "Recycle flush disabled"
        return 0
      fi

      # ---------------- ON -----------------
      local cron
      cron="$(parse_timer "$timer")"

      say "Installing recycle flush cron in CT $CTID ($timer)"

      ct "cat > /root/nas-recycle-cron.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE=\"/etc/nas/state.env\"
SMB_CONF=\"/etc/samba/smb.conf\"

[[ -f \"\$STATE_FILE\" ]] || exit 0
# shellcheck disable=SC1090
source \"\$STATE_FILE\"

[[ -n \"\${MP_IN:-}\" ]] || exit 0

# Try samba homes path first
homes_path=\"\$(
  awk '
    BEGIN{i=0}
    /^[[:space:]]*\\[homes\\]$/{i=1;next}
    i && /^\\[/{exit}
    i && /^\\s*path\\s*=/{sub(/^[^=]*=/,\"\");print;exit}
  ' \"\$SMB_CONF\"
)\"

# If not defined (MODE=1), fall back to MP_IN
[[ -n \"\$homes_path\" ]] || homes_path=\"\$MP_IN\"

homes_path=\"\${homes_path//%U/}\"
homes_path=\"\${homes_path%/}\"

find \"\$homes_path\" -type d -path '*/.recycle/*' 2>/dev/null |
while read -r d; do
  [[ \"\$(basename \"\$(dirname \"\$d\")\")\" == \".recycle\" ]] || continue
  find -P \"\$d\" -mindepth 1 -xdev -delete
done
EOF"

      ct "chmod +x /root/nas-recycle-cron.sh"

      ct "printf '%s root /root/nas-recycle-cron.sh >> /var/log/nas-recycle.log 2>&1\n' \
        '$cron' > /etc/cron.d/nas-recycle"

      say "Recycle flush scheduled: $cron"
      ;;

    "" | flush )
      # immediate one-off cleanup
      local d
      find_homes_user_recycle_bins | while read -r d; do
        [[ "$(basename "$(dirname "$d")")" == ".recycle" ]] || continue
        warn "Emptying: $d"
        ct "find -P '$d' -mindepth 1 -xdev -delete"
      done
      ;;

    *)
      die "Usage: recycle [flush|timer <Nm|Nh|Nd|off>]"
      ;;
  esac
}

case "$CMD" in
  info)     cmd_info ;;
  smb)      cmd_smb "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  recycle)  cmd_recycle "$@" ;;
  *)        die "Unknown command" ;;
esac
