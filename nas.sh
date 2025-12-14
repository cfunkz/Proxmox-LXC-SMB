#!/usr/bin/env bash
# Proxmox ZFS + Samba NAS in (un)privileged LXC
#
# Storage modes:
#  1) Single dataset: BASE with subdirs homes/[Shared]/[Public]/[Guest]
#  2) Per-user datasets: BASE/homes/<user> (+ optional BASE/Shared, BASE/Public, BASE/Guest datasets)
#
# Share rules (unchanged):
#  - Homes: private; only user + @nas_admin. No browsing/enum of other usernames.
#  - Shared (optional): everyone read; only file owners can edit/delete (sticky dir).
#  - Public (optional): everyone read; only @nas_public + @nas_admin can write.
#  - Guest  (optional): guest read-only; @nas_admin write.
#
# Script behavior:
#  - If NOT installed: performs full install once and writes /etc/nas/state.env in the CT.
#  - If installed: uses /etc/nas/state.env for layout + mode and jumps to management:
#       quotas, users, enable/disable shares, recycle, allowed subnets, workgroup.
#
# Run on Proxmox host as root.
# Version: 2025-12-13

set -Eeuo pipefail

# -------------------- UI helpers --------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
say()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YEL}$*${NC}"; }
die()  { echo -e "${RED}Error: $*${NC}" >&2; exit 1; }
ask()  { local r; read -rp "$1" r; echo "${r:-$2}"; }

# -------------------- Globals (state + rollback) --------------------
CTID=""; CONF=""; UNPRIV=0; IDOFF=0
MP_IN="/srv/nas"

POOL=""; BASENAME=""; BASE=""; BASE_MNT=""; BASE_PREEXIST=0
MODE=""; IS_INSTALLED=0

CREATE_SHARED=0; CREATE_PUBLIC=0; CREATE_GUEST=0
ENABLE_HOMES_RECYCLE=0
ALLOWED_SUBNETS=""; WORKGROUP="WORKGROUP"

DATASETS_CREATED=()
declare -A DATASET_QUOTA_OLD
DIRS_CREATED=()
LXC_MOUNTS_CREATED=()
CT_USERS_CREATED=()
CT_GROUPS_CREATED=()
USERS_SUMMARY=()
SMB_CONF_BACKUP=""
SMB_CONF_TOUCHED=0

STATE_FILE="/etc/nas/state.env"

# -------------------- Rollback handler --------------------
on_err() {
  local ec=$?
  warn "Error (exit code $ec). Rolling back changes from this run..."
  set +e

  if [[ -n "${CTID:-}" ]]; then
    if [[ -n "${SMB_CONF_BACKUP:-}" ]]; then
      warn "RB: restoring /etc/samba/smb.conf from backup in CT $CTID"
      pct exec "$CTID" -- bash -lc "cp '$SMB_CONF_BACKUP' /etc/samba/smb.conf 2>/dev/null || true"
    elif [[ "${SMB_CONF_TOUCHED:-0}" -eq 1 ]]; then
      warn "RB: removing /etc/samba/smb.conf created by this run in CT $CTID"
      pct exec "$CTID" -- bash -lc "rm -f /etc/samba/smb.conf 2>/dev/null || true"
    fi

    for u in "${CT_USERS_CREATED[@]:-}"; do
      warn "RB: deleting user '$u' in CT $CTID"
      pct exec "$CTID" -- bash -lc "pdbedit -x '$u' >/dev/null 2>&1 || smbpasswd -x '$u' >/dev/null 2>&1 || true"
      pct exec "$CTID" -- bash -lc "id '$u' >/dev/null 2>&1 && userdel -r '$u' >/dev/null 2>&1 || true"
    done

    for g in "${CT_GROUPS_CREATED[@]:-}"; do
      warn "RB: deleting group '$g' in CT $CTID"
      pct exec "$CTID" -- bash -lc "getent group '$g' >/dev/null 2>&1 && groupdel '$g' >/dev/null 2>&1 || true"
    done

    if [[ -n "${CONF:-}" && -f "$CONF" ]]; then
      for mp in "${LXC_MOUNTS_CREATED[@]:-}"; do
        warn "RB: removing mountpoint '$mp' from CT $CTID"
        pct set "$CTID" -delete "$mp" >/dev/null 2>&1 || true
      done
    fi
  fi

  for d in "${DIRS_CREATED[@]:-}"; do
    warn "RB: removing directory $d"
    rmdir "$d" >/dev/null 2>&1 || true
  done

  for ds in "${!DATASET_QUOTA_OLD[@]}"; do
    local old="${DATASET_QUOTA_OLD[$ds]}"
    if [[ "$old" == "-" ]]; then
      warn "RB: restoring quota=none for $ds"
      zfs set quota=none "$ds" >/dev/null 2>&1 || true
    else
      warn "RB: restoring quota=$old for $ds"
      zfs set quota="$old" >/dev/null 2>&1 || true
    fi
  done

  for ((i=${#DATASETS_CREATED[@]}-1; i>=0; i--)); do
    local ds="${DATASETS_CREATED[$i]}"
    warn "RB: destroying dataset $ds"
    zfs destroy -r "$ds" >/dev/null 2>&1 || true
  done

  echo -e "${RED}Rollback complete.${NC}"
  exit "$ec"
}
trap on_err ERR

# -------------------- Validation helpers --------------------
validate_username() { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1; }
validate_ds()       { [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1; }
validate_workgroup() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,15}$ ]] || return 1; }
validate_cidr_list() {
  local IFS=',' cidr
  for cidr in $1; do
    [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || return 1
  done
}

# -------------------- Core helpers --------------------
ct_exec() { pct exec "$CTID" -- bash -lc "$*"; }

host_uid() { [[ $UNPRIV -eq 1 ]] && echo $((IDOFF + $1)) || echo "$1"; }
host_gid() { [[ $UNPRIV -eq 1 ]] && echo $((IDOFF + $1)) || echo "$1"; }

mkds() {
  local ds="$1"
  if zfs list "$ds" >/dev/null 2>&1; then return 0; fi
  say "Creating dataset: $ds"
  zfs create -p \
    -o compression=zstd \
    -o atime=off \
    -o xattr=sa \
    -o acltype=posixacl \
    -o aclinherit=passthrough \
    -o aclmode=passthrough \
    "$ds"
  DATASETS_CREATED+=("$ds")
  return 0
}

dsmp() { zfs get -H -o value mountpoint "$1"; }

save_quota_old() {
  local ds="$1"
  if [[ -z "${DATASET_QUOTA_OLD[$ds]+x}" ]]; then
    local old
    old="$(zfs get -H -o value quota "$ds" 2>/dev/null || echo "-")"
    DATASET_QUOTA_OLD["$ds"]="$old"
  fi
  return 0
}

set_quota_if_any() {
  # Keep behavior: empty input does nothing
  local ds="$1" label="$2" q
  q="$(ask "Quota for $label (e.g. 1T, 500G; empty = none): " "")"
  if [[ -n "$q" ]]; then
    save_quota_old "$ds"
    say "Setting quota=$q on $ds"
    zfs set quota="$q" "$ds"
  fi
  return 0
}

next_mp_index() {
  awk -F: '/^mp[0-9]+:/{sub(/^mp/, "", $1); if ($1+0 > m) m=$1+0} END{print (m?m:0)+1}' \
    "$CONF" 2>/dev/null || echo 0
}

conf_has_ctpath_mount() {
  local ct_path="$1"
  awk -F: -v p="$ct_path" '$1 ~ /^mp[0-9]+$/ && $2 ~ (",mp="p"([, ]|$)") {found=1} END{exit !found}' "$CONF" 2>/dev/null
}

bind_mount() {
  # Adds bind mount only if CT doesn't already have a mount for ct_path
  local host_path="$1" ct_path="$2"
  if conf_has_ctpath_mount "$ct_path"; then
    say "Reusing existing mount -> $ct_path"
    return 0
  fi

  ct_exec "mkdir -p '$ct_path'"
  local idx key
  idx="$(next_mp_index)"
  key="mp${idx}"

  say "Adding mount: $host_path -> $ct_path ($key)"
  pct set "$CTID" -${key} "${host_path},mp=${ct_path}"
  LXC_MOUNTS_CREATED+=("$key")
  return 0
}

ensure_base_mount() {
  local base_mnt="$1"
  bind_mount "$base_mnt" "$MP_IN"
  return 0
}

create_group_if_missing() {
  local g="$1"
  if ! ct_exec "getent group '$g' >/dev/null 2>&1"; then
    say "Creating group '$g' in CT $CTID"
    ct_exec "groupadd '$g'"
    CT_GROUPS_CREATED+=("$g")
  fi
  return 0
}

# -------------------- State (.env) management --------------------
load_state() {
  # Load /etc/nas/state.env inside CT, if present
  if ct_exec "[[ -f '$STATE_FILE' ]]" >/dev/null 2>&1; then
    local env_content
    env_content="$(ct_exec "cat '$STATE_FILE'")" || die "Failed to read $STATE_FILE from CT $CTID"
    eval "$env_content"

    BASE="${BASE_DATASET:-}"
    [[ -z "$BASE" ]] && die "$STATE_FILE missing BASE_DATASET"

    BASE_MNT="$(dsmp "$BASE")"
    [[ -d "$BASE_MNT" ]] || die "ZFS mountpoint for $BASE (from $STATE_FILE) not found"

    MP_IN="${MP_IN:-/srv/nas}"
    MODE="${MODE:-1}"
    CREATE_SHARED="${CREATE_SHARED:-0}"
    CREATE_PUBLIC="${CREATE_PUBLIC:-0}"
    CREATE_GUEST="${CREATE_GUEST:-0}"
    ENABLE_HOMES_RECYCLE="${ENABLE_HOMES_RECYCLE:-0}"
    WORKGROUP="${WORKGROUP:-WORKGROUP}"
    ALLOWED_SUBNETS="${ALLOWED_SUBNETS:-}"

    IS_INSTALLED=1
  else
    IS_INSTALLED=0
  fi
  return 0
}

save_state() {
  ct_exec "mkdir -p /etc/nas"
  pct exec "$CTID" -- bash -lc "cat > '$STATE_FILE'" <<EOF
BASE_DATASET=$BASE
MODE=$MODE
MP_IN=$MP_IN
CREATE_SHARED=$CREATE_SHARED
CREATE_PUBLIC=$CREATE_PUBLIC
CREATE_GUEST=$CREATE_GUEST
ENABLE_HOMES_RECYCLE=$ENABLE_HOMES_RECYCLE
WORKGROUP=$WORKGROUP
ALLOWED_SUBNETS='${ALLOWED_SUBNETS}'
EOF
  return 0
}

# -------------------- Installer detection (unprivileged) --------------------
detect_container_unprivileged() {
  UNPRIV=0; IDOFF=0
  if grep -q '^unprivileged:\s*1' "$CONF"; then
    UNPRIV=1
    IDOFF="$(grep -E '^lxc.idmap = u 0 ' "$CONF" | awk '{print $5}' | head -n1 || echo 100000)"
    say "Unprivileged CT detected (idmap offset $IDOFF)."
  else
    say "Privileged CT detected."
  fi
  return 0
}

ensure_container_running_and_samba() {
  if ! pct status "$CTID" | grep -q running; then
    say "Starting container $CTID ..."
    pct start "$CTID"
  fi

  # Ensure Samba tools exist inside CT (install if missing)
  ct_exec 'command -v smbd >/dev/null && command -v smbpasswd >/dev/null && command -v testparm >/dev/null' \
    || ct_exec 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y samba' \
    || die "Samba tools missing in CT $CTID and install failed."
  return 0
}

# -------------------- Prompts (no logic change) --------------------
prompt_mode() {
  echo "Storage layout modes:"
  echo "  1) Single dataset (subdirs: homes, [Shared], [Public], [Guest])"
  echo "  2) Per-user datasets (homes/<user>), [Shared], [Public], [Guest]"
  MODE="$(ask 'Select mode [1/2] (default 1): ' 1)"
  [[ "$MODE" =~ ^[12]$ ]] || MODE=1
  return 0
}

prompt_optional_shares() {
  local a
  a="$(ask 'Create Shared share (read for all, edit for creators)? [y/N]: ' n)"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_SHARED=1 || CREATE_SHARED=0

  a="$(ask 'Create Public share (read-only for all, nas_public for write)? [y/N]: ' n)"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_PUBLIC=1 || CREATE_PUBLIC=0

  a="$(ask 'Create Guest share (read-only for guest)? [y/N]: ' n)"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_GUEST=1 || CREATE_GUEST=0
  return 0
}

prompt_network_workgroup_recycle() {
  while true; do
    ALLOWED_SUBNETS="$(ask 'Allowed subnets (comma separated, empty = allow all): ' "${ALLOWED_SUBNETS:-}")"
    [[ -z "$ALLOWED_SUBNETS" ]] && break
    validate_cidr_list "$ALLOWED_SUBNETS" && break
    warn "Invalid subnet format. Use e.g. 192.168.1.0/24,10.0.0.0/8"
  done

  while true; do
    WORKGROUP="$(ask 'Samba workgroup (default WORKGROUP): ' "${WORKGROUP:-WORKGROUP}")"
    validate_workgroup "$WORKGROUP" && break
    warn "Invalid workgroup. Use 1–15 chars: letters, numbers, dash, underscore."
  done

  local r
  r="$(ask 'Enable recycle bin for home directories? [y/N]: ' $([[ $ENABLE_HOMES_RECYCLE -eq 1 ]] && echo y || echo n))"
  [[ "$r" =~ ^[Yy]$ ]] && ENABLE_HOMES_RECYCLE=1 || ENABLE_HOMES_RECYCLE=0
  return 0
}

# -------------------- ZFS base dataset selection (install mode) --------------------
prompt_pool_and_base_dataset() {
  say "Available ZFS pools:"
  zpool list
  echo
  read -rp "ZFS pool name: " POOL
  validate_ds "$POOL" || die "Invalid pool name."
  zpool list "$POOL" >/dev/null 2>&1 || die "Pool '$POOL' not found."

  say "Existing datasets under pool '$POOL':"
  zfs list -r "$POOL" || true
  echo

  read -rp "Base dataset name under $POOL (e.g. nas): " BASENAME
  validate_ds "$BASENAME" || die "Invalid dataset name."
  [[ -n "$BASENAME" ]] || die "Base dataset name cannot be empty."

  BASE="${POOL}/${BASENAME}"
  BASE_PREEXIST=0
  if zfs list "$BASE" >/dev/null 2>&1; then
    BASE_PREEXIST=1
    warn "Reusing existing base dataset: $BASE"
  else
    read -rp "Create base dataset $BASE? [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || die "Base dataset does not exist; aborting."
    mkds "$BASE"
  fi

  BASE_MNT="$(dsmp "$BASE")"
  [[ -d "$BASE_MNT" ]] || die "Base dataset mountpoint $BASE_MNT does not exist."

  if [[ $UNPRIV -eq 1 && $BASE_PREEXIST -eq 0 ]]; then
    chown "$(host_uid 0):$(host_gid 0)" "$BASE_MNT"
  fi
  return 0
}

# -------------------- Layout (preserves current logic) --------------------
ensure_ct_base_dirs() {
  ensure_base_mount "$BASE_MNT"
  ct_exec "mkdir -p '$MP_IN' '$MP_IN/homes'"
  [[ $CREATE_SHARED -eq 1 ]] && ct_exec "mkdir -p '${MP_IN}/Shared'"
  [[ $CREATE_PUBLIC -eq 1 ]] && ct_exec "mkdir -p '${MP_IN}/Public'"
  [[ $CREATE_GUEST  -eq 1 ]] && ct_exec "mkdir -p '${MP_IN}/Guest'"
  return 0
}

layout_mode1_hostdirs() {
  # Mode 1: directories inside BASE_MNT (host), homes always exists; others optional
  if [[ ! -d "$BASE_MNT/homes" ]]; then
    mkdir -p "$BASE_MNT/homes"
    DIRS_CREATED+=("$BASE_MNT/homes")
  fi
  chmod 0711 "$BASE_MNT/homes"

  if [[ $CREATE_SHARED -eq 1 ]]; then
    if [[ ! -d "$BASE_MNT/Shared" ]]; then
      mkdir -p "$BASE_MNT/Shared"
      DIRS_CREATED+=("$BASE_MNT/Shared")
    fi
    chmod 1777 "$BASE_MNT/Shared"
  fi

  if [[ $CREATE_PUBLIC -eq 1 ]]; then
    if [[ ! -d "$BASE_MNT/Public" ]]; then
      mkdir -p "$BASE_MNT/Public"
      DIRS_CREATED+=("$BASE_MNT/Public")
    fi
    local gid_ct gid_host
    gid_ct="$(ct_exec "getent group nas_public | cut -d: -f3")"
    gid_host="$(host_gid "$gid_ct")"
    chown "0:${gid_host}" "$BASE_MNT/Public"
    chmod 0775 "$BASE_MNT/Public"
  fi

  if [[ $CREATE_GUEST -eq 1 ]]; then
    if [[ ! -d "$BASE_MNT/Guest" ]]; then
      mkdir -p "$BASE_MNT/Guest"
      DIRS_CREATED+=("$BASE_MNT/Guest")
    fi
    chmod 0755 "$BASE_MNT/Guest"
  fi

  return 0
}

layout_mode2_datasets_and_mounts() {
  # Mode 2: BASE/homes dataset mounted to MP_IN/homes, optional share datasets
  local ds mnt gid_ct gid_host

  ds="${BASE}/homes"
  mkds "$ds"
  mnt="$(dsmp "$ds")"
  [[ $UNPRIV -eq 1 ]] && chown "$(host_uid 0):$(host_gid 0)" "$mnt"
  chmod 0711 "$mnt"
  bind_mount "$mnt" "${MP_IN}/homes"

  if [[ $CREATE_SHARED -eq 1 ]]; then
    ds="${BASE}/Shared"
    mkds "$ds"
    set_quota_if_any "$ds" "Shared"
    mnt="$(dsmp "$ds")"
    [[ $UNPRIV -eq 1 ]] && chown "$(host_uid 0):$(host_gid 0)" "$mnt"
    chmod 1777 "$mnt"
    bind_mount "$mnt" "${MP_IN}/Shared"
  fi

  if [[ $CREATE_PUBLIC -eq 1 ]]; then
    ds="${BASE}/Public"
    mkds "$ds"
    set_quota_if_any "$ds" "Public"
    mnt="$(dsmp "$ds")"
    [[ $UNPRIV -eq 1 ]] && chown "$(host_uid 0):$(host_gid 0)" "$mnt"
    gid_ct="$(ct_exec "getent group nas_public | cut -d: -f3")"
    gid_host="$(host_gid "$gid_ct")"
    chown "0:${gid_host}" "$mnt"
    chmod 0775 "$mnt"
    bind_mount "$mnt" "${MP_IN}/Public"
  fi

  if [[ $CREATE_GUEST -eq 1 ]]; then
    ds="${BASE}/Guest"
    mkds "$ds"
    set_quota_if_any "$ds" "Guest"
    mnt="$(dsmp "$ds")"
    [[ $UNPRIV -eq 1 ]] && chown "$(host_uid 0):$(host_gid 0)" "$mnt"
    chmod 0755 "$mnt"
    bind_mount "$mnt" "${MP_IN}/Guest"
  fi

  return 0
}

ensure_homes_parent_perm_in_ct() {
  ct_exec "chmod 0711 '${MP_IN}/homes' || true"
  return 0
}

# -------------------- User creation (same behavior) --------------------
create_users_flow() {
  say "Create Samba users (for homes, Shared, Public, etc.)"

  while true; do
    local add local_user p1 p2 is_admin has_public_rw
    add="$(ask 'Add a user? [y/N]: ' n)"
    [[ "$add" =~ ^[Yy]$ ]] || break

    local_user=""
    while [[ -z "$local_user" ]]; do
      read -rp "Username: " local_user
      validate_username "$local_user" && break
      warn "Invalid username."
      local_user=""
    done

    read -rsp "Password: " p1; echo ""
    read -rsp "Confirm password: " p2; echo ""
    [[ "$p1" == "$p2" ]] || { warn "Password mismatch; skipping user $local_user."; continue; }

    is_admin="$(ask "Add $local_user to nas_admin (Samba admin)? [y/N]: " n)"
    has_public_rw="$(ask "Allow $local_user write access to Public (nas_public)? [y/N]: " n)"

    if ct_exec "id '$local_user' >/dev/null 2>&1"; then
      warn "User '$local_user' already exists in CT; reusing and updating Samba/groups."
    else
      say "Creating user '$local_user' in CT $CTID"
      ct_exec "useradd -M -d '${MP_IN}/homes/${local_user}' -s /usr/sbin/nologin -g nas_users '$local_user'"
      CT_USERS_CREATED+=("$local_user")
    fi

    if [[ "$MODE" == "1" ]]; then
      ct_exec "mkdir -p '${MP_IN}/homes/${local_user}'"
      ct_exec "chown '${local_user}:nas_users' '${MP_IN}/homes/${local_user}'"
      ct_exec "chmod 700 '${MP_IN}/homes/${local_user}'"
    else
      local user_ds user_mnt uid_ct gid_ct
      user_ds="${BASE}/homes/${local_user}"
      mkds "$user_ds"
      set_quota_if_any "$user_ds" "home of ${local_user}"

      user_mnt="$(dsmp "$user_ds")"
      uid_ct="$(ct_exec "id -u '$local_user'")"
      gid_ct="$(ct_exec "id -g '$local_user'")"

      chown "$(host_uid "$uid_ct"):$(host_gid "$gid_ct")" "$user_mnt"
      chmod 700 "$user_mnt"

      bind_mount "$user_mnt" "${MP_IN}/homes/${local_user}"
    fi

    if [[ $ENABLE_HOMES_RECYCLE -eq 1 ]]; then
      ct_exec "mkdir -p '${MP_IN}/homes/${local_user}/.recycle/${local_user}'"
      ct_exec "chown -R '${local_user}:nas_users' '${MP_IN}/homes/${local_user}/.recycle' && chmod 700 '${MP_IN}/homes/${local_user}/.recycle/${local_user}'"
      ct_exec "ln -snf '.recycle/${local_user}' '${MP_IN}/homes/${local_user}/Recycle Bin'"
    fi

    [[ "$is_admin" =~ ^[Yy]$ ]]      && ct_exec "usermod -aG nas_admin '$local_user'"
    [[ "$has_public_rw" =~ ^[Yy]$ ]] && ct_exec "usermod -aG nas_public '$local_user'"
    ct_exec "usermod -aG nas_users '$local_user'"

    pct exec "$CTID" -- bash -lc "chpasswd" <<<"${local_user}:${p1}"
    pct exec "$CTID" -- bash -lc "smbpasswd -s -a '$local_user'" <<<"$p1"$'\n'"$p1"

    USERS_SUMMARY+=("${local_user}|$([[ "$is_admin" =~ ^[Yy]$ ]] && echo yes || echo no)|$([[ "$has_public_rw" =~ ^[Yy]$ ]] && echo yes || echo no)")
    say "User '$local_user' configured."
  done

  return 0
}

# -------------------- Samba configuration writer --------------------
write_smb_conf() {
  # Backup existing smb.conf (if present)
  if ct_exec '[[ -f /etc/samba/smb.conf ]]'; then
    SMB_CONF_BACKUP="/etc/samba/smb.conf.bak.$(date +%s)"
    say "Backing up existing /etc/samba/smb.conf to $SMB_CONF_BACKUP inside CT"
    ct_exec "cp /etc/samba/smb.conf '$SMB_CONF_BACKUP'"
  fi

  SMB_CONF_TOUCHED=1
  local tmp; tmp="$(mktemp)"

  cat > "$tmp" <<EOF
# Managed by proxmox-nas-installer (do not hand-edit unless you know what you're doing)
[global]
   workgroup = ${WORKGROUP}
   server string = Proxmox NAS
   server role = standalone server
   security = user
   aio read size = 1
   aio write size = 1

   log file = /var/log/samba/log.%m
   max log size = 1000
   log level = 1

   # Protocol hardening
   server min protocol = SMB2_10
   client min protocol = SMB2_10
   server max protocol = SMB3_11
   client max protocol = SMB3_11

   # Signing disabled for lan
   server signing = disabled

   # ACL / xattr
   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes
   inherit acls = yes
   ea support = yes

   map to guest = Bad User
   guest account = nobody

   disable netbios = yes
   dns proxy = no

   restrict anonymous = 2
   null passwords = no

   access based share enum = yes
   hide unreadable = yes
   hide dot files = yes

   unix extensions = no
   follow symlinks = yes
   wide links = no
EOF

  if [[ -n "$ALLOWED_SUBNETS" ]]; then
    echo "   hosts allow = ${ALLOWED_SUBNETS}" >> "$tmp"
    echo "   hosts deny  = ALL" >> "$tmp"
  fi

  cat >> "$tmp" <<EOF

[homes]
   comment = Home Directories
   browseable = no
   read only = no
   valid users = %S
   admin users = @nas_admin
   create mask = 0600
   directory mask = 0700
EOF

  if [[ $ENABLE_HOMES_RECYCLE -eq 1 ]]; then
    cat >> "$tmp" <<EOF
   vfs objects = acl_xattr recycle
   recycle:repository = .recycle/%U
   recycle:keeptree = yes
   recycle:versions = yes
   recycle:touch = yes
   recycle:touch_mtime = yes
   recycle:directory_mode = 0700
   recycle:subdir_mode = 0700
EOF
  else
    cat >> "$tmp" <<EOF
   vfs objects = acl_xattr
EOF
  fi

  if [[ $CREATE_SHARED -eq 1 ]]; then
    cat >> "$tmp" <<EOF

[Shared]
   path = ${MP_IN}/Shared
   comment = Shared (everyone read, only owners edit/delete)
   browseable = yes
   read only = no
   guest ok = no
   valid users = @nas_users @nas_admin
   admin users = @nas_admin
   create mask = 0644
   force create mode = 0644
   directory mask = 0755
   force directory mode = 0755
   inherit acls = yes
EOF
  fi

  if [[ $CREATE_PUBLIC -eq 1 ]]; then
    cat >> "$tmp" <<EOF

[Public]
   path = ${MP_IN}/Public
   comment = Public (RO for all, RW for nas_public/admin)
   browseable = yes
   read only = yes
   guest ok = no
   valid users = @nas_users @nas_public @nas_admin
   write list = @nas_public @nas_admin
   force group = nas_public
   create mask = 0664
   force create mode = 0664
   directory mask = 2775
   force directory mode = 2775
   inherit acls = yes
EOF
  fi

  if [[ $CREATE_GUEST -eq 1 ]]; then
    cat >> "$tmp" <<EOF

[Guest]
   path = ${MP_IN}/Guest
   comment = Guest (guest read-only, admin write)
   browseable = yes
   read only = no
   write list = @nas_admin
   admin users = @nas_admin
   guest ok = yes
   public = yes
EOF
  fi

  pct exec "$CTID" -- bash -lc "cat > /etc/samba/smb.conf" < "$tmp"
  rm -f "$tmp"

  ct_exec "testparm -s /etc/samba/smb.conf >/dev/null"
  ct_exec "systemctl restart smbd 2>/dev/null || service smbd restart 2>/dev/null || true"
  ct_exec "systemctl restart nmbd 2>/dev/null || service nmbd restart 2>/dev/null || true"
  ct_exec "systemctl restart winbind 2>/dev/null || service winbind restart 2>/dev/null || true"

  return 0
}

# -------------------- Quota management (installed mode) --------------------
quota_management_flow() {
  local doq
  doq="$(ask 'Change ZFS quotas now? [y/N]: ' n)"
  [[ "$doq" =~ ^[Yy]$ ]] || return 0

  if [[ "$MODE" == "1" ]]; then
    set_quota_if_any "$BASE" "base dataset $BASE"
  else
    # Mode 2: base, homes parent, shares, and optional per-user datasets
    set_quota_if_any "$BASE" "base dataset $BASE"

    if zfs list "${BASE}/homes" >/dev/null 2>&1; then
      set_quota_if_any "${BASE}/homes" "homes parent dataset ${BASE}/homes"
    fi

    [[ $CREATE_SHARED -eq 1 && $(zfs list -H -o name "${BASE}/Shared" 2>/dev/null || true) ]] && set_quota_if_any "${BASE}/Shared" "Shared"
    [[ $CREATE_PUBLIC -eq 1 && $(zfs list -H -o name "${BASE}/Public" 2>/dev/null || true) ]] && set_quota_if_any "${BASE}/Public" "Public"
    [[ $CREATE_GUEST  -eq 1 && $(zfs list -H -o name "${BASE}/Guest"  2>/dev/null || true) ]] && set_quota_if_any "${BASE}/Guest"  "Guest"

    local peru
    peru="$(ask 'Set quota for existing home datasets under BASE/homes/<user>? [y/N]: ' n)"
    if [[ "$peru" =~ ^[Yy]$ ]]; then
      local ds
      while IFS= read -r ds; do
        [[ "$ds" == "${BASE}/homes" ]] && continue
        set_quota_if_any "$ds" "home dataset $ds"
      done < <(zfs list -H -o name -r "${BASE}/homes" 2>/dev/null || true)
    fi
  fi

  return 0
}

# -------------------- Summary --------------------
print_summary() {
  local ip
  ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  echo -e "\n${GREEN}NAS setup complete.${NC}\n"
  echo "Container: $CTID"
  [[ -n "$ip" ]] && echo "Container IP: $ip"
  echo "Base dataset: $BASE (mountpoint: $BASE_MNT)"
  echo "Mode: $MODE"
  echo
  echo "Shares:"
  echo "  Homes   : \\\\${ip}\\<username> (private, not browsable; no other usernames visible)"
  [[ $CREATE_SHARED -eq 1 ]] && echo "  Shared  : \\\\${ip}\\Shared"
  [[ $CREATE_PUBLIC -eq 1 ]] && echo "  Public  : \\\\${ip}\\Public"
  [[ $CREATE_GUEST  -eq 1 ]] && echo "  Guest   : \\\\${ip}\\Guest"
  echo
  echo "Groups inside CT:"
  echo "  nas_users  : all NAS users"
  echo "  nas_public : users allowed to write to Public"
  echo "  nas_admin  : Samba admins"
  if ((${#USERS_SUMMARY[@]})); then
    echo
    echo "Created/updated users:"
    local uline u is_admin pub_rw
    for uline in "${USERS_SUMMARY[@]}"; do
      IFS='|' read -r u is_admin pub_rw <<<"$uline"
      echo "  - $u   (admin: $is_admin, public_write: $pub_rw)"
    done
  fi
  echo
  echo "Data paths inside CT:"
  echo "  Base mount : $MP_IN"
  echo "  Homes      : $MP_IN/homes/<user> (parent 0711, homes 0700)"
  [[ $CREATE_SHARED -eq 1 ]] && echo "  Shared     : $MP_IN/Shared"
  [[ $CREATE_PUBLIC -eq 1 ]] && echo "  Public     : $MP_IN/Public"
  [[ $CREATE_GUEST  -eq 1 ]] && echo "  Guest      : $MP_IN/Guest"
  echo
  return 0
}

# -------------------- Container selection (always first) --------------------
select_container() {
  echo -e "${BLU}== Proxmox ZFS + Samba NAS installer ==${NC}\n"
  [[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
  command -v pct   >/dev/null 2>&1 || die "pct not found (Proxmox host only)."
  command -v zfs   >/dev/null 2>&1 || die "ZFS tools not found."
  command -v zpool >/dev/null 2>&1 || die "ZFS tools not found."

  say "Existing containers:"
  pct list || true
  echo

  read -rp "Container ID (CTID): " CTID
  [[ "$CTID" =~ ^[0-9]+$ ]] || die "Invalid CTID."
  pct status "$CTID" >/dev/null 2>&1 || die "CT $CTID not found."

  CONF="/etc/pve/lxc/${CTID}.conf"
  [[ -f "$CONF" ]] || die "Missing LXC config: $CONF"

  detect_container_unprivileged
  ensure_container_running_and_samba
  return 0
}

# -------------------- Flows --------------------
install_flow() {
  # Fresh install: ask where to mount inside CT
  MP_IN="$(ask 'Mount base inside CT (default /srv/nas): ' /srv/nas)"

  prompt_mode
  prompt_pool_and_base_dataset
  prompt_optional_shares

  if [[ "$MODE" == "1" ]]; then
    set_quota_if_any "$BASE" "base dataset $BASE"
    say "Mode 1 selected: using $BASE as a single dataset with subdirectories."
  else
    say "Mode 2 selected: per-user datasets + optional Shared/Public/Guest under $BASE."
  fi

  create_group_if_missing "nas_admin"
  create_group_if_missing "nas_public"
  create_group_if_missing "nas_users"

  ensure_ct_base_dirs

  if [[ "$MODE" == "1" ]]; then
    layout_mode1_hostdirs
  else
    layout_mode2_datasets_and_mounts
  fi

  ensure_homes_parent_perm_in_ct
  prompt_network_workgroup_recycle
  create_users_flow
  write_smb_conf
  save_state
  return 0
}

management_flow() {
  warn "Detected existing NAS install in CT $CTID."
  say  "Entering management mode (no destructive deletes; shares can be enabled/disabled logically)."

  create_group_if_missing "nas_admin"
  create_group_if_missing "nas_public"
  create_group_if_missing "nas_users"

  local a
  a="$(ask "Enable Shared share? [y/N] (current: $([[ $CREATE_SHARED -eq 1 ]] && echo enabled || echo disabled)): " $([[ $CREATE_SHARED -eq 1 ]] && echo y || echo n))"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_SHARED=1 || CREATE_SHARED=0
  a="$(ask "Enable Public share? [y/N] (current: $([[ $CREATE_PUBLIC -eq 1 ]] && echo enabled || echo disabled)): " $([[ $CREATE_PUBLIC -eq 1 ]] && echo y || echo n))"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_PUBLIC=1 || CREATE_PUBLIC=0
  a="$(ask "Enable Guest share? [y/N] (current: $([[ $CREATE_GUEST -eq 1 ]] && echo enabled || echo disabled)): " $([[ $CREATE_GUEST -eq 1 ]] && echo y || echo n))"
  [[ "$a" =~ ^[Yy]$ ]] && CREATE_GUEST=1 || CREATE_GUEST=0

  ensure_ct_base_dirs
  if [[ "$MODE" == "1" ]]; then
    layout_mode1_hostdirs
  else
    layout_mode2_datasets_and_mounts
  fi
  ensure_homes_parent_perm_in_ct

  prompt_network_workgroup_recycle
  quota_management_flow
  create_users_flow
  write_smb_conf
  save_state
  return 0
}

# -------------------- Main --------------------
main() {
  select_container
  load_state

  if [[ $IS_INSTALLED -eq 1 ]]; then
    management_flow
  else
    install_flow
  fi

  trap - ERR
  print_summary
}
main "$@"
