#!/usr/bin/env bash
# Disaster-recovery backup/restore with incremental rsync snapshots (k8s).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"
ui_style_task_output
cd "$ROOT"
# shellcheck source=scripts/backup-encrypt.sh
source "${ROOT}/scripts/backup-encrypt.sh"
NS=vaultwarden
STACK_ID="vaultwarden-k8s"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

need_rsync() {
  command -v rsync >/dev/null 2>&1 || {
    echo "Missing: rsync (needed for incremental snapshots)." >&2
    exit 1
  }
}

usage() {
  cat <<EOF
Usage:
  ./manage.sh backup --dest /mnt/backup [--keep N]
  ./manage.sh backup --restore --from /path/to/backup-root-or-snapshot
  ./manage.sh backup --help

Disaster-recovery backups (also used by ./manage.sh update for pre-update snapshots into ./backups).

  --dest DIR    Backup root; writes to DIR/<stack-id>/snapshots/...
                Uses rsync hardlinks against the previous snapshot so
                unchanged files are not duplicated on disk.
  --keep N      After backup, keep only the newest N snapshots (default: no prune).
  --restore     Restore into this deployment from --from.
  --from PATH   Backup root (uses latest/) or a specific snapshots/TIMESTAMP dir.

  --archive FMT      After snapshot, also write a compressed export (tar.gz|tar.xz|zip).
                     Local hardlink snapshots stay uncompressed for --link-dest.
  --archive-password Password-protect that archive:
                       zip   -> zip -e (ZipCrypto; casual protection)
                       tar.* -> compress then age -p (strong passphrase)
  --encrypt          Advanced: age-encrypted .tar.age export (recipient key).
  --export-dir DIR   Where to put exports (default: DEST/exports for --archive,
                     DEST/encrypted for --encrypt).
  --age-recipient R  age1... public key or path to recipients file (repeatable).
  --age-identity F   Private key file for decrypt (default: ~/.config/johnycsf/backup.age.key).
  --passphrase       With --encrypt: age -p instead of a recipient key.

  SHA256SUMS = integrity. Archives/age = smaller or confidential offsite copies.
  Restore: --from may be a snapshot dir/root OR *.tar.gz / *.tar.xz / *.zip /
  *.tar.gz.age / *.tar.xz.age / *.tar.age / *.age.

Fresh-machine workflow:
  1) Install this stack on the new host (./manage.sh) so runtime exists.
  2) ./manage.sh backup --restore --from /mnt/usb/my-backups
  3) Script replaces data/secrets and finishes app-specific repair (e.g. Nextcloud scan).

Database safety:
  MariaDB/Nextcloud  - logical dump (--single-transaction), never live datadir copy.
  SQLite apps       - service stopped/scaled down, WAL checkpoint, then file copy.
  Incremental rsync applies to files; each MariaDB dump is a full verified SQL file.
EOF
}

MODE=""
DEST=""
FROM=""
KEEP=""

ENCRYPT="${BACKUP_ENCRYPT:-0}"
EXPORT_DIR="${BACKUP_EXPORT_DIR:-}"
ENCRYPT_PASSPHRASE=0
ARCHIVE_FORMAT="${BACKUP_ARCHIVE:-}"
ARCHIVE_PASSWORD="${BACKUP_ARCHIVE_PASSWORD:-0}"
AGE_RECIPIENTS=()
AGE_IDENTITY="${BACKUP_AGE_IDENTITY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "--dest needs a path" >&2; exit 1; }
      DEST="$2"; MODE="${MODE:-backup}"; shift 2 ;;
    --from)
      [[ $# -ge 2 ]] || { echo "--from needs a path" >&2; exit 1; }
      FROM="$2"; shift 2 ;;
    --restore)
      MODE="restore"; shift ;;
    --archive)
      [[ $# -ge 2 ]] || { echo "--archive needs tar.gz|tar.xz|zip" >&2; exit 1; }
      ARCHIVE_FORMAT="$2"; shift 2 ;;
    --archive-password)
      ARCHIVE_PASSWORD=1; shift ;;
    --encrypt)
      ENCRYPT=1; shift ;;
    --export-dir)
      [[ $# -ge 2 ]] || { echo "--export-dir needs a path" >&2; exit 1; }
      EXPORT_DIR="$2"; shift 2 ;;
    --age-recipient)
      [[ $# -ge 2 ]] || { echo "--age-recipient needs a value" >&2; exit 1; }
      AGE_RECIPIENTS+=("$2"); shift 2 ;;
    --age-identity)
      [[ $# -ge 2 ]] || { echo "--age-identity needs a path" >&2; exit 1; }
      AGE_IDENTITY="$2"; shift 2 ;;
    --passphrase)
      ENCRYPT=1; ENCRYPT_PASSPHRASE=1; shift ;;
    --keep)
      [[ $# -ge 2 ]] || { echo "--keep needs a number" >&2; exit 1; }
      KEEP="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

stamp_now() { date +%Y%m%d-%H%M%S; }

resolve_snapshot_dir() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Not found: $path" >&2
    exit 1
  fi
  path="$(cd "$path" && pwd)"
  if [[ -f "${path}/META.txt" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ -L "${path}/latest" ]]; then
    local target=""
    if target="$(readlink -f "${path}/latest" 2>/dev/null)"; then
      :
    else
      target="$(readlink "${path}/latest")"
      [[ "$target" == /* ]] || target="${path}/${target}"
    fi
    if [[ -f "${target}/META.txt" ]]; then
      printf '%s\n' "$(cd "$target" && pwd)"
      return 0
    fi
  fi
  # newest snapshots/*
  local newest
  newest="$(ls -1dt "${path}"/snapshots/* 2>/dev/null | head -1 || true)"
  if [[ -n "$newest" && -f "${newest}/META.txt" ]]; then
    printf '%s\n' "$(cd "$newest" && pwd)"
    return 0
  fi
  echo "No usable snapshot under: $path" >&2
  echo "Expected META.txt in a snapshot dir, or a backup root with latest/ / snapshots/." >&2
  exit 1
}

prepare_snapshot_dirs() {
  local dest="$1"
  mkdir -p "${dest}/snapshots"
  SNAP_NAME="$(stamp_now)"
  SNAP_DIR="${dest}/snapshots/${SNAP_NAME}"
  mkdir -p "${SNAP_DIR}"
  PREV_LINK=""
  if [[ -L "${dest}/latest" ]]; then
    PREV_LINK="$(readlink "${dest}/latest")"
    if [[ "${PREV_LINK}" != /* ]]; then
      PREV_LINK="${dest}/${PREV_LINK}"
    fi
  fi
}

finalize_snapshot() {
  local dest="$1"
  ln -sfn "snapshots/${SNAP_NAME}" "${dest}/latest"
  echo "Snapshot ready: ${SNAP_DIR}"
  echo "Latest pointer: ${dest}/latest -> snapshots/${SNAP_NAME}"
}

prune_snapshots() {
  local dest="$1"
  local keep="$2"
  [[ -n "$keep" ]] || return 0
  keep="$(printf '%s' "$keep" | tr -dc '0-9')"
  [[ -n "$keep" && "$keep" -ge 1 ]] || return 0
  mapfile -t snaps < <(ls -1dt "${dest}"/snapshots/* 2>/dev/null || true)
  local total="${#snaps[@]}"
  if (( total <= keep )); then
    echo "Retention: keeping all ${total} snapshot(s) (limit ${keep})."
    return 0
  fi
  local i
  for (( i = keep; i < total; i++ )); do
    echo "Pruning old snapshot: ${snaps[$i]}"
    rm -rf "${snaps[$i]}"
  done
}

rsync_incremental() {
  # rsync_incremental SRC_DIR DEST_FILES_DIR PREV_FILES_DIR_OR_EMPTY
  local src="$1"
  local dst="$2"
  local prev="${3:-}"
  mkdir -p "$dst"
  local -a args=(-aH --delete --info=stats2)
  if [[ -n "$prev" && -d "$prev" ]]; then
    args+=(--link-dest="$prev")
    echo "    Incremental vs: $prev"
  else
    echo "    Full copy (first snapshot or no previous files/)."
  fi
  rsync "${args[@]}" "${src}/" "${dst}/"
}


# --- Snapshot integrity (SHA256) ---
# Payload files are listed in SHA256SUMS. META.txt holds snapshot_sha256 (hash of SHA256SUMS).
# Restore verifies and WARNS on mismatch but does not abort.
sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "unavailable"
  fi
}

seal_snapshot() {
  local snap="$1"
  echo "==> Sealing snapshot with SHA256 manifests..."
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "WARNING: sha256sum/shasum not found - snapshot will lack integrity key." >&2
    return 0
  fi
  (
    cd "$snap" || exit 1
    rm -f SHA256SUMS
    if command -v sha256sum >/dev/null 2>&1; then
      find . -type f ! -name SHA256SUMS ! -name META.txt -print0 \
        | sort -z \
        | xargs -0 -r sha256sum >SHA256SUMS
    else
      : >SHA256SUMS
      find . -type f ! -name SHA256SUMS ! -name META.txt -print0 | sort -z | while IFS= read -r -d '' f; do
        printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f" >>SHA256SUMS
      done
    fi
    if [[ ! -s SHA256SUMS ]]; then
      echo "WARNING: SHA256SUMS is empty (no payload files?)." >&2
    fi
  )
  local sum
  sum="$(sha256_file "${snap}/SHA256SUMS")"
  if [[ ! -f "${snap}/META.txt" ]]; then
    printf 'stack=unknown\ncreated=%s\n' "$(date -Iseconds)" >"${snap}/META.txt"
  fi
  if grep -q '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null; then
    sed -i "s|^snapshot_sha256=.*|snapshot_sha256=${sum}|" "${snap}/META.txt"
  else
    printf 'snapshot_sha256=%s\n' "$sum" >>"${snap}/META.txt"
  fi
  echo "    snapshot_sha256=${sum}"
  echo "    Wrote SHA256SUMS + META snapshot_sha256 key."
}

verify_snapshot_integrity() {
  local snap="$1"
  local warn=0
  echo "==> Checking snapshot integrity (SHA256)..."
  if [[ ! -f "${snap}/SHA256SUMS" ]]; then
    echo "WARNING: No SHA256SUMS manifest - cannot verify integrity (legacy or incomplete backup)." >&2
    echo "         Restore will continue, but corruption cannot be ruled out." >&2
    return 0
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "WARNING: sha256sum not found - skipping per-file check." >&2
    warn=1
  else
    local out
    set +e
    out="$(cd "$snap" && sha256sum -c SHA256SUMS 2>&1)"
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "WARNING: SHA256 file verification FAILED - integrity is lost; restore may cause issues." >&2
      printf '%s\n' "$out" | grep -v ': OK$' | head -n 40 >&2 || true
      warn=1
    fi
  fi
  local expected actual
  expected="$(grep -E '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null | cut -d= -f2- || true)"
  actual="$(sha256_file "${snap}/SHA256SUMS")"
  if [[ -z "$expected" || "$expected" == "unavailable" ]]; then
    echo "WARNING: META.txt has no snapshot_sha256 key." >&2
    warn=1
  elif [[ "$actual" != "$expected" ]]; then
    echo "WARNING: SHA256SUMS does not match META snapshot_sha256 - integrity is lost; restore may cause issues." >&2
    echo "         expected=${expected}" >&2
    echo "         actual=${actual}" >&2
    warn=1
  fi
  if [[ "$warn" -eq 0 ]]; then
    echo "    Integrity OK (snapshot_sha256=${actual})."
  else
    echo "    Continuing restore despite integrity warnings (not aborting)." >&2
  fi
  return 0
}

write_meta() {
  local snap="$1"
  local stack="$2"
  local note="$3"
  cat >"${snap}/META.txt" <<EOF
stack=${stack}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=${note}
EOF
}




# --- SQLite safety (stop/quiesce, checkpoint WAL, then copy; never copy a live DB) ---
sqlite_checkpoint_tree() {
  local root="$1"
  command -v sqlite3 >/dev/null 2>&1 || {
    echo "    sqlite3 CLI not on host - relying on stopped service + full file copy (incl. -wal/-shm)."
    return 0
  }
  local db count=0
  while IFS= read -r -d '' db; do
    echo "    Checkpointing SQLite: $db"
    sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
    count=$((count + 1))
  done < <(find "$root" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name 'db.sqlite3' -o -name 'app.sqlite' \) -print0 2>/dev/null)
  echo "    Checkpointed ${count} SQLite file(s)."
}

verify_sqlite_tree() {
  local root="$1"
  local found=0
  local db
  while IFS= read -r -d '' db; do
    found=1
    if [[ ! -s "$db" ]]; then
      echo "SQLite file empty after backup: $db" >&2
      return 1
    fi
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$db" "PRAGMA integrity_check;" | grep -qx 'ok' || {
        echo "SQLite integrity_check failed: $db" >&2
        return 1
      }
    fi
    echo "    OK SQLite: $db ($(wc -c <"$db" | tr -d ' ') bytes)"
  done < <(find "$root" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name 'db.sqlite3' -o -name 'app.sqlite' \) -print0 2>/dev/null)
  if [[ "$found" -eq 0 ]]; then
    echo "Warning: no SQLite DB file found under $root (app may be empty/new)." >&2
  fi
}


pull_pod_tree() {
  local pod="$1" remote="$2" dest="$3"
  mkdir -p "$dest"
  kubectl -n "$NS" exec "$pod" -- tar -C "$remote" -cf - . | tar -C "$dest" -xf -
}

push_pod_tree() {
  local pod="$1" remote="$2" src="$3"
  kubectl -n "$NS" exec "$pod" -- sh -c "rm -rf ${remote}/* ${remote}/.[!.]* ${remote}/..?* 2>/dev/null || true"
  tar -C "$src" -cf - . | kubectl -n "$NS" exec -i "$pod" -- tar -C "$remote" -xf -
}

do_backup() {
  need kubectl
  need_rsync
  [[ -n "$DEST" ]] || { echo "Provide --dest /path" >&2; exit 1; }
  DEST="$(resolve_stack_backup_dest "${STACK_ID}" "${DEST}")"
  DEST="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
  echo "==> Stack backup root: ${DEST}"
  prepare_snapshot_dirs "$DEST"
  echo "==> Snapshot ${SNAP_NAME} -> ${SNAP_DIR}"
  echo "==> DB strategy: scale to 0, SQLite WAL checkpoint, then incremental copy."
  # Brief scale-down for consistent SQLite
  restore_vw_service() {
    kubectl -n "$NS" delete pod vw-backup-helper --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$NS" scale deployment/vaultwarden --replicas=1 >/dev/null 2>&1 || true
  }
  trap restore_vw_service EXIT

  echo "==> Scaling Vaultwarden to 0 for a consistent data copy..."
  kubectl -n "$NS" scale deployment/vaultwarden --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=vaultwarden --timeout=120s 2>/dev/null || true

  # Start a one-shot helper using the same PVC
  kubectl -n "$NS" delete pod vw-backup-helper --ignore-not-found >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vw-backup-helper
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: ${IMAGE_REGISTRY:-docker.io}/vaultwarden/server:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: vaultwarden-data
EOF
  kubectl -n "$NS" wait --for=condition=Ready pod/vw-backup-helper --timeout=120s

  local staging
  staging="$(mktemp -d)"
  pull_pod_tree vw-backup-helper /data "${staging}/files"
  sqlite_checkpoint_tree "${staging}/files"
  local prev_files=""
  [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files" ]] && prev_files="${PREV_LINK}/files"
  rsync_incremental "${staging}/files" "${SNAP_DIR}/files" "${prev_files}"
  verify_sqlite_tree "${SNAP_DIR}/files"
  rm -rf "$staging"

  kubectl -n "$NS" get secret vaultwarden -o yaml >"${SNAP_DIR}/secret-vaultwarden.yaml" 2>/dev/null || true
  [[ -f "${ROOT}/.admin-token" ]] && cp -a "${ROOT}/.admin-token" "${SNAP_DIR}/"
  cp -a "${ROOT}/deploy.yaml" "${SNAP_DIR}/" 2>/dev/null || true
  cat >"${SNAP_DIR}/META.txt" <<EOF
stack=${STACK_ID}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=vaultwarden /data after scale-0 + sqlite checkpoint
db_engine=sqlite
db_method=scale0+wal_checkpoint+rsync
EOF

  trap - EXIT
  restore_vw_service
  kubectl -n "$NS" rollout status deployment/vaultwarden --timeout=180s
  seal_snapshot "${SNAP_DIR}"
  maybe_encrypt_after_seal
  finalize_snapshot "$DEST"
  prune_snapshots "$DEST" "${KEEP}"
  echo "Tip: store this backup root on an external drive or NAS."
}

do_restore() {
  need kubectl
  need_rsync
  [[ -n "$FROM" ]] || { echo "Provide --from /path" >&2; exit 1; }
  FROM="$(resolve_stack_backup_from "${STACK_ID}" "${FROM}")"
  local snap src
  src="$(prepare_restore_from_arg "$FROM")"
  trap cleanup_restore_tmp EXIT
  snap="$(resolve_snapshot_dir "$src")"
  echo "Restoring from: $snap"
  verify_snapshot_integrity "$snap"
  [[ -d "${snap}/files" ]] || { echo "Missing files/" >&2; exit 1; }
  echo
  echo "Recommended: ./manage.sh on the new cluster first, then restore."
  read -r -p "Type 'restore' to continue: " confirm || true
  [[ "${confirm}" == "restore" ]] || { echo "Aborted."; exit 1; }

  if ! kubectl -n "$NS" get deploy vaultwarden >/dev/null 2>&1; then
    apply_manifest "${ROOT}/deploy.yaml"
  fi
  if [[ -f "${snap}/secret-vaultwarden.yaml" ]]; then
    kubectl -n "$NS" apply -f "${snap}/secret-vaultwarden.yaml"
  fi
  [[ -f "${snap}/.admin-token" ]] && cp -a "${snap}/.admin-token" "${ROOT}/.admin-token"

  kubectl -n "$NS" scale deployment/vaultwarden --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=vaultwarden --timeout=120s 2>/dev/null || true
  kubectl -n "$NS" delete pod vw-restore-helper --ignore-not-found >/dev/null 2>&1 || true
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vw-restore-helper
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
    - name: helper
      image: ${IMAGE_REGISTRY:-docker.io}/vaultwarden/server:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: vaultwarden-data
EOF
  kubectl -n "$NS" wait --for=condition=Ready pod/vw-restore-helper --timeout=120s
  push_pod_tree vw-restore-helper /data "${snap}/files"
  kubectl -n "$NS" delete pod vw-restore-helper --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NS" scale deployment/vaultwarden --replicas=1
  kubectl -n "$NS" rollout status deployment/vaultwarden --timeout=180s
  echo "Restore finished from ${snap}."
}

case "${MODE}" in
  backup) do_backup ;;
  restore) do_restore ;;
  *) usage >&2; exit 1 ;;
esac
