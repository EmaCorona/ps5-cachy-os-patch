#!/usr/bin/env bash
# ==============================================================================
# lib/modules/gamescope.sh - Configurazione Gamescope Gaming Mode (Auto-rilevamento DRM)
# ==============================================================================

module_gamescope_info() {
    echo "Configurazione Gamescope Gaming Mode (auto-rilevamento risoluzione nativa DRM/EDID, cap_sys_nice, log)"
}

module_gamescope_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Gamescope: Configurazione sessione Gamescope Gaming Mode (auto-rilevamento risoluzione DRM)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Configura template opzionale /etc/ps5-gamescope.conf se non esiste
    sudo mkdir -p "${cachy_mnt}/etc"
    if [ ! -f "${cachy_mnt}/etc/ps5-gamescope.conf" ]; then
        cat << 'EOF' | sudo tee "${cachy_mnt}/etc/ps5-gamescope.conf" >/dev/null
# /etc/ps5-gamescope.conf - Configurazione opzionale Gamescope PS5
# Lasciare commentato per utilizzare l'auto-rilevamento dinamico nativo via DRM/EDID.

# Risoluzione fisica del display (Output)
# PS5_OUTPUT_WIDTH=1920
# PS5_OUTPUT_HEIGHT=1080

# Risoluzione interna di rendering UI e giochi (Nested)
# Utile su TV 4K per renderizzare a 1080p e scalare in 4K con FSR:
# PS5_NESTED_WIDTH=1920
# PS5_NESTED_HEIGHT=1080

# Refresh rate forzato (es. 60 o 120). Di default Gamescope negozia il refresh nativo dello schermo.
# PS5_REFRESH_RATE=60

# Connettore di output preferito (default: DP-1,HDMI-A-1 o auto-rilevato)
# PS5_OUTPUT_CONN="DP-1"
EOF
        sudo chmod 0644 "${cachy_mnt}/etc/ps5-gamescope.conf"
    fi

    # 1b. Configura il profilo portali XDG per Gamescope (evita fallback su portali KDE/plasmanotify)
    sudo mkdir -p "${cachy_mnt}/usr/share/xdg-desktop-portal"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/share/xdg-desktop-portal/gamescope-portals.conf" >/dev/null
[preferred]
default=gtk
EOF
    sudo chmod 0644 "${cachy_mnt}/usr/share/xdg-desktop-portal/gamescope-portals.conf"

    # 1c. Installa utility di verifica e riparazione integrità Steam da cache locale (.zip / .zip.vz)
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-steam-verify-repair" >/dev/null
#!/usr/bin/env bash
# ps5-steam-verify-repair: Verifica le dimensioni dei file in package/*.installed
# e ripara automaticamente eventuali librerie/binari troncati estraendoli dagli archivi .zip.vz / .zip locali.

STEAM_DIR="${1:-${PS5_STEAM_DIR:-/home/steam/.local/share/Steam}}"
PKG_DIR="${STEAM_DIR}/package"

[ -d "$PKG_DIR" ] || exit 0

if command -v python3 >/dev/null 2>&1; then
    python3 - "$STEAM_DIR" << 'PYEOF'
import io
import lzma
import os
import struct
import sys
import zipfile

steam_dir = sys.argv[1]
pkg_dir = os.path.join(steam_dir, "package")
if not os.path.isdir(pkg_dir):
    sys.exit(0)

installed_manifests = sorted(
    os.path.join(pkg_dir, f)
    for f in os.listdir(pkg_dir)
    if f.endswith(".installed") and os.path.isfile(os.path.join(pkg_dir, f))
)
if not installed_manifests:
    sys.exit(0)

corrupted = {}  # rel_path -> (expected_size, expected_crc, manifest_path)
for manifest in installed_manifests:
    try:
        with open(manifest, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith(("SIGNATURE:", "OSVER=", "VERSION=", "SHA1=")):
                    continue
                rel_path = ""
                exp_size = -1
                exp_crc = None
                if "\t" in line:
                    parts = line.split("\t")
                    rel_path = parts[0].strip()
                    size_field = [p for p in parts if p.startswith("size=")]
                    if size_field:
                        exp_size = int(size_field[0].split("=")[1])
                elif ";" in line and "," in line.split(";")[0]:
                    semi_parts = line.split(";")
                    path_and_size = semi_parts[0]
                    rel_path, size_str = path_and_size.rsplit(",", 1)
                    exp_size = int(size_str)
                    if len(semi_parts) >= 3 and semi_parts[2].isdigit():
                        exp_crc = int(semi_parts[2])
                if not rel_path or exp_size < 0:
                    continue
                full_path = os.path.join(steam_dir, rel_path)
                if not os.path.exists(full_path):
                    corrupted[rel_path] = (exp_size, exp_crc, manifest)
                else:
                    try:
                        act_size = os.path.getsize(full_path)
                        if act_size != exp_size:
                            corrupted[rel_path] = (exp_size, exp_crc, manifest)
                    except OSError:
                        corrupted[rel_path] = (exp_size, exp_crc, manifest)
    except OSError:
        continue

if not corrupted:
    sys.exit(0)

print(f"[ps5-steam-verify-repair] Rilevati {len(corrupted)} file Steam troncati o mancanti. Avvio ripristino da cache package/...")

def open_valve_archive(arc_path):
    if zipfile.is_zipfile(arc_path):
        return zipfile.ZipFile(arc_path, "r")
    with open(arc_path, "rb") as f:
        data = f.read()
    if len(data) < 22 or data[:3] != b"VZa":
        raise ValueError("Invalid archive header")
    props = data[7:12]
    _, uncomp_size = struct.unpack("<II", data[-10:-2])
    lzma_header = props + struct.pack("<Q", uncomp_size)
    raw_zip = lzma.decompress(lzma_header + data[12:-10], format=lzma.FORMAT_ALONE)
    return zipfile.ZipFile(io.BytesIO(raw_zip), "r")

archives = sorted(
    (
        os.path.join(pkg_dir, f)
        for f in os.listdir(pkg_dir)
        if ".zip" in f and os.path.isfile(os.path.join(pkg_dir, f))
    ),
    key=lambda p: os.path.getmtime(p),
    reverse=True,
)

repaired = set()
fallback_candidates = {}  # rel_path -> (raw_bytes, mode)

for arc_path in archives:
    if len(repaired) == len(corrupted):
        break
    try:
        with open_valve_archive(arc_path) as zf:
            names = set(zf.namelist())
            for rel_path, (exp_size, exp_crc, _) in corrupted.items():
                if rel_path in repaired or rel_path not in names:
                    continue
                info = zf.getinfo(rel_path)
                mode = (info.external_attr >> 16) & 0o777
                if info.file_size == exp_size and (exp_crc is None or info.CRC == exp_crc):
                    payload = zf.read(rel_path)
                    full_path = os.path.join(steam_dir, rel_path)
                    os.makedirs(os.path.dirname(full_path), exist_ok=True)
                    tmp_path = full_path + ".ps5repair.tmp"
                    with open(tmp_path, "wb") as out:
                        out.write(payload)
                    if mode:
                        os.chmod(tmp_path, mode)
                    os.replace(tmp_path, full_path)
                    repaired.add(rel_path)
                    print(f"[ps5-steam-verify-repair] Ripristinato: {rel_path} ({exp_size} byte) da {os.path.basename(arc_path)}")
                elif rel_path not in fallback_candidates and info.file_size > 0:
                    fallback_candidates[rel_path] = (zf.read(rel_path), mode)
    except Exception:
        continue

for rel_path, (exp_size, _, manifest) in corrupted.items():
    if rel_path in repaired:
        continue
    if rel_path in fallback_candidates:
        payload, mode = fallback_candidates[rel_path]
        full_path = os.path.join(steam_dir, rel_path)
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        tmp_path = full_path + ".ps5repair.tmp"
        with open(tmp_path, "wb") as out:
            out.write(payload)
        if mode:
            os.chmod(tmp_path, mode)
        os.replace(tmp_path, full_path)
        repaired.add(rel_path)
        print(f"[ps5-steam-verify-repair] Ripristinato (fallback archivio): {rel_path} ({len(payload)} byte)")

unrepaired_manifests = {manifest for rel_path, (_, _, manifest) in corrupted.items() if rel_path not in repaired}
for manifest in unrepaired_manifests:
    try:
        os.remove(manifest)
        print(f"[ps5-steam-verify-repair] Rimosso manifesto {os.path.basename(manifest)} per forzare ri-estrazione pulita di Steam.")
    except OSError:
        pass
PYEOF
    if [ "$(id -u)" -eq 0 ] && [ -d "$STEAM_DIR" ]; then
        chown -R 1000:1000 "$STEAM_DIR" 2>/dev/null || true
    fi
    exit 0
fi

# Fallback POSIX/awk se python3 non è disponibile: verifica taglie e invalida il manifesto corrotto
for manifest in "$PKG_DIR"/*.installed; do
    [ -f "$manifest" ] || continue
    corrupt_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in SIGNATURE:*|OSVER=*|VERSION=*|SHA1=*) continue ;; esac
        rel_path=""
        exp_size=""
        case "$line" in
            *";"*","*)
                first_part="${line%%;*}"
                rel_path="${first_part%,*}"
                exp_size="${first_part##*,}"
                ;;
            *size=*)
                rel_path="${line%%	*}"
                exp_size="${line#*size=}"
                exp_size="${exp_size%%	*}"
                ;;
        esac
        case "$exp_size" in
            ""|-*) continue ;;
        esac
        full_path="${STEAM_DIR}/${rel_path}"
        if [ ! -e "$full_path" ]; then
            corrupt_count=$((corrupt_count + 1))
            break
        fi
        act_size=$(stat -c %s "$full_path" 2>/dev/null || echo -1)
        if [ "$act_size" != "$exp_size" ]; then
            corrupt_count=$((corrupt_count + 1))
            break
        fi
    done < "$manifest"
    if [ "$corrupt_count" -gt 0 ]; then
        echo "[ps5-steam-verify-repair] Rilevati file troncati in $(basename "$manifest"); rimozione manifesto per forzare ri-estrazione."
        rm -f "$manifest" 2>/dev/null || true
    fi
done
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-steam-verify-repair"

    # 1b. Configura script ps5-drm-setup e servizio early-boot per limitare a 8bpc il bridge DisplayPort->HDMI Panasonic (MN864739)
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-drm-setup" >/dev/null
#!/bin/bash
# ps5-drm-setup: configure DRM connector properties for PS5 Panasonic MN864739 DP-to-HDMI bridge.
# The internal APU connects to the Panasonic bridge via DisplayPort (DP-1).
# By default, amdgpu negotiates 10/12 bpc (max bpc = 16) on 4K TVs, which the bridge
# cannot translate, producing a black HDMI screen while audio/gamescope continues running.
# Setting 'max bpc' to 8 ensures standard 8bpc/24bpp RGB output compatible with the bridge.

LOG_FILE="/var/log/ps5-drm-setup.log"
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
log() {
    local msg="[$(date -Is)] ps5-drm-setup: $*"
    if [ -w /var/log ] || [ -w "$LOG_FILE" ]; then
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
    ps5_log drm info "$*"
    echo "$msg" >&2
}

log "Avvio configurazione proprietà DRM (max bpc = 8)..."

PROPTEST_BIN=""
if command -v proptest >/dev/null 2>&1; then
    PROPTEST_BIN="proptest"
elif [ -x /usr/bin/proptest ]; then
    PROPTEST_BIN="/usr/bin/proptest"
fi

if [ -z "$PROPTEST_BIN" ]; then
    log "proptest non trovato in PATH o /usr/bin."
    exit 0
fi

if command -v python3 >/dev/null 2>&1; then
    python3 - "$PROPTEST_BIN" << 'PYEOF'
import sys, re, subprocess

proptest_bin = sys.argv[1]
try:
    res = subprocess.run([proptest_bin], capture_output=True, text=True, check=False)
    output = res.stdout
except Exception as e:
    print(f"[ps5-drm-setup] Errore esecuzione proptest: {e}", file=sys.stderr)
    sys.exit(0)

curr_id = None
curr_name = None

for line in output.splitlines():
    m_conn = re.match(r"^Connector\s+(\d+)\s+\(([^)]+)\)", line)
    if m_conn:
        curr_id, curr_name = m_conn.group(1), m_conn.group(2)
        continue
    if curr_id and curr_name and curr_name.startswith(("DP-", "HDMI-")):
        m_bpc = re.match(r"^\s+(\d+)\s+max\s+bpc:", line)
        if m_bpc:
            prop_id = m_bpc.group(1)
            print(f"[ps5-drm-setup] Imposto max bpc=8 su connettore {curr_name} (id={curr_id}, prop={prop_id})", file=sys.stderr)
            subprocess.run([proptest_bin, curr_id, "connector", prop_id, "8"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        m_col = re.match(r"^\s+(\d+)\s+Colorspace:", line)
        if m_col:
            prop_id = m_col.group(1)
            print(f"[ps5-drm-setup] Imposto Colorspace=Default su connettore {curr_name} (id={curr_id}, prop={prop_id})", file=sys.stderr)
            subprocess.run([proptest_bin, curr_id, "connector", prop_id, "0"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
PYEOF
    log "Configurazione DRM completata via python3."
    exit 0
fi

re_conn='^Connector[[:space:]]+([0-9]+)[[:space:]]+\(([^)]+)\)'
re_bpc='^[[:space:]]+([0-9]+)[[:space:]]+max[[:space:]]+bpc:'
re_col='^[[:space:]]+([0-9]+)[[:space:]]+Colorspace:'

CURRENT_CONN_ID=""
CURRENT_CONN_NAME=""

PROPTEST_OUT="$("$PROPTEST_BIN" 2>/dev/null)" || {
    log "Errore durante l'esecuzione di proptest."
    exit 0
}

while IFS= read -r line; do
    if [[ "$line" =~ $re_conn ]]; then
        CURRENT_CONN_ID="${BASH_REMATCH[1]}"
        CURRENT_CONN_NAME="${BASH_REMATCH[2]}"
        continue
    fi
    if [ -n "$CURRENT_CONN_ID" ]; then
        case "$CURRENT_CONN_NAME" in
            DP-*|HDMI-*)
                if [[ "$line" =~ $re_bpc ]]; then
                    prop_id="${BASH_REMATCH[1]}"
                    log "Imposto max bpc=8 su connettore ${CURRENT_CONN_NAME} (id=${CURRENT_CONN_ID}, prop=${prop_id})"
                    "$PROPTEST_BIN" "$CURRENT_CONN_ID" connector "$prop_id" 8 >/dev/null 2>&1 || true
                elif [[ "$line" =~ $re_col ]]; then
                    prop_id="${BASH_REMATCH[1]}"
                    log "Imposto Colorspace=Default su connettore ${CURRENT_CONN_NAME} (id=${CURRENT_CONN_ID}, prop=${prop_id})"
                    "$PROPTEST_BIN" "$CURRENT_CONN_ID" connector "$prop_id" 0 >/dev/null 2>&1 || true
                fi
                ;;
        esac
    fi
done <<< "$PROPTEST_OUT"

log "Configurazione DRM completata."
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-drm-setup"

    # Disabilita e rimuove il servizio early-boot ps5-drm-setup se presente
    # (l'invocazione di proptest a livello di sysinit.target interferisce con lo stato KMS atomico del kernel)
    sudo rm -f "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/ps5-drm-setup.service" 2>/dev/null || true
    sudo rm -f "${cachy_mnt}/etc/systemd/system/ps5-drm-setup.service" 2>/dev/null || true

    # 1d. Installa utility diagnostica non invasiva della catena video (P1/P3/P4 e separazione rendering/presentazione)
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-video-diag" >/dev/null
#!/bin/bash
# ps5-video-diag: Analisi non invasiva della catena video DRM/KMS su PS5
# Rendering -> Swapchain -> DRM/KMS presentation -> Scanout AMDGPU DCN 2.0.1 -> Bridge MN864739 -> Display
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

LOG_FILE="${PS5_VIDEO_DIAG_LOG:-/var/log/ps5-video-diag.log}"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

ps5_log video info "ps5-video-diag: inizio diagnostica pipeline video..."

report() {
    echo "$*"
    echo "[$(date -Is 2>/dev/null || date)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

report "=== PS5 Video Pipeline Diagnostic Report ==="
report "Data: $(date -Is 2>/dev/null || date)"
report "Kernel: $(uname -r 2>/dev/null || echo 'sconosciuto')"

# 1. Ispezione Sysfs Connettori DRM
report "--- 1. Stato Connettori DRM (/sys/class/drm) ---"
HAS_CONNECTED=0
ACTIVE_CONN=""
ACTIVE_STATUS=""
ACTIVE_DPMS=""
ACTIVE_ENABLED=""
ACTIVE_MODE=""

for c in /sys/class/drm/card*-*; do
    [ -d "$c" ] || continue
    c_name="${c##*/}"
    status=$(cat "$c/status" 2>/dev/null || echo "unknown")
    dpms=$(cat "$c/dpms" 2>/dev/null || echo "unknown")
    enabled=$(cat "$c/enabled" 2>/dev/null || echo "unknown")
    top_mode=$(head -n 1 "$c/modes" 2>/dev/null || echo "none")
    all_modes=$(tr '\n' ' ' < "$c/modes" 2>/dev/null || echo "none")
    report "Connettore: $c_name | Status: $status | DPMS: $dpms | Enabled: $enabled | Top Mode: $top_mode"
    if [ "$status" = "connected" ]; then
        HAS_CONNECTED=1
        ACTIVE_CONN="$c_name"
        ACTIVE_STATUS="$status"
        ACTIVE_DPMS="$dpms"
        ACTIVE_ENABLED="$enabled"
        ACTIVE_MODE="$top_mode"
        report "  Modalita disponibili: $all_modes"
    fi
done

if [ "$HAS_CONNECTED" -eq 0 ]; then
    report "DIAGNOSI FISICA: [ASSENZA DI SEGNALE] Nessun connettore collegato rilevato nel sysfs."
elif [ "$ACTIVE_DPMS" = "Off" ] || [ "$ACTIVE_DPMS" = "Standby" ] || [ "$ACTIVE_DPMS" = "Suspend" ]; then
    report "DIAGNOSI FISICA: [ASSENZA DI SEGNALE / DPMS BLANK] Connettore collegato ($ACTIVE_CONN) ma stato DPMS=$ACTIVE_DPMS."
else
    report "DIAGNOSI FISICA: [SEGNALE ATTIVO] Connettore collegato ($ACTIVE_CONN), DPMS=$ACTIVE_DPMS, Risoluzione=$ACTIVE_MODE."
fi

# 2. Ispezione Proprieta Atomiche DRM (modetest)
report "--- 2. Proprieta Atomiche KMS (modetest) ---"
if command -v modetest >/dev/null 2>&1; then
    MT_CONN=$(modetest -M amdgpu -c 2>/dev/null | grep -A 25 "Connectors:" || echo "")
    if [ -n "$MT_CONN" ]; then
        report "$MT_CONN"
    else
        report "modetest: nessun output su modulo amdgpu"
    fi
else
    report "modetest non installato nel sistema"
fi

# 3. Telemetria Rendering Gamescope vs Presentazione DRM
report "--- 3. Telemetria Gamescope & Steam ---"
GS_PID=$(pgrep -x gamescope 2>/dev/null || pgrep -f "/usr/bin/gamescope" 2>/dev/null | head -n 1 || echo "")
STEAM_PID=$(pgrep -x steam 2>/dev/null || echo "")

if [ -n "$GS_PID" ]; then
    report "Processo Gamescope: ATTIVO (PID: $GS_PID)"
else
    report "Processo Gamescope: NON ATTIVO"
fi

if [ -n "$STEAM_PID" ]; then
    report "Processo Steam: ATTIVO (PID: $STEAM_PID)"
else
    report "Processo Steam: NON ATTIVO"
fi

STATS_JSON=""
for p in /run/user/*/gamescope-stats.json /tmp/gamescope-stats.json /home/steam/gamescope-stats.json; do
    if [ -f "$p" ]; then
        STATS_JSON="$p"
        break
    fi
done

if [ -n "$STATS_JSON" ]; then
    report "Telemetria Gamescope trovata in: $STATS_JSON"
    report "$(cat "$STATS_JSON" 2>/dev/null | head -n 30)"
else
    report "Nessun file di telemetria gamescope-stats.json trovato."
fi

# 4. Sintesi Diagnostica P1/P4
report "--- 4. Sintesi Diagnostica Finale ---"
if [ "$HAS_CONNECTED" -eq 1 ] && [ "$ACTIVE_DPMS" = "On" ] && [ -n "$GS_PID" ]; then
    report "RISULTATO: Segnale video e handshake HDMI ATTIVI con risoluzione $ACTIVE_MODE. Gamescope in esecuzione."
    report "Se il display e nero, il problema e confermato nel livello di PRESENTAZIONE/SCANOUT (necessari --force-composition e --disable-layers su DCN 2.0.1)."
elif [ "$HAS_CONNECTED" -eq 0 ]; then
    report "RISULTATO: Nessun display fisico rilevato. Verificare cavo HDMI e bridge."
fi
report "=== Fine Report ==="
ps5_log video info "ps5-video-diag completato con successo (salvato $LOG_FILE)"
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-video-diag"

    # Configura variabili globali d'ambiente 8bpc/SDR in /etc/environment
    if [ -f "${cachy_mnt}/etc/environment" ]; then
        grep -q "KWIN_DRM_PREFER_COLOR_DEPTH" "${cachy_mnt}/etc/environment" 2>/dev/null || \
            echo "KWIN_DRM_PREFER_COLOR_DEPTH=24" | sudo tee -a "${cachy_mnt}/etc/environment" >/dev/null
        grep -q "KWIN_FORCE_ASSUME_HDR_SUPPORT" "${cachy_mnt}/etc/environment" 2>/dev/null || \
            echo "KWIN_FORCE_ASSUME_HDR_SUPPORT=0" | sudo tee -a "${cachy_mnt}/etc/environment" >/dev/null
    fi

    # 1e. Compila e installa lo shim libps5-drm-8bpc.so per forzare Gamescope su DRM_FORMAT_XRGB8888 (24bpp / 8bpc)
    sudo mkdir -p "${cachy_mnt}/usr/local/lib" "${cachy_mnt}/usr/local/src"
    cat << 'SHIM_EOF' | sudo tee "${cachy_mnt}/usr/local/src/ps5-drm-8bpc.c" >/dev/null
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

#define DRM_CAP_ADDFB2_MODIFIERS 0x10

#define DRM_FORMAT_XRGB2101010  0x30335258
#define DRM_FORMAT_ARGB2101010  0x30335241
#define DRM_FORMAT_XBGR2101010  0x30334258
#define DRM_FORMAT_ABGR2101010  0x30334241
#define DRM_FORMAT_RGBA1010102  0x30334152
#define DRM_FORMAT_BGRA1010102  0x30334142

typedef struct _drmModePlane {
    uint32_t count_formats;
    uint32_t *formats;
    uint32_t plane_id;
    uint32_t crtc_id;
    uint32_t fb_id;
    uint32_t crtc_x, crtc_y;
    uint32_t x, y;
    uint32_t possible_crtcs;
    uint32_t gamma_size;
} drmModePlane, *drmModePlanePtr;

typedef drmModePlanePtr (*orig_drmModeGetPlane_fn)(int fd, uint32_t plane_id);
typedef int (*orig_drmGetCap_fn)(int fd, uint64_t capability, uint64_t *value);

int drmGetCap(int fd, uint64_t capability, uint64_t *value) {
    if (capability == DRM_CAP_ADDFB2_MODIFIERS) {
        if (value) *value = 0;
        static int logged_cap = 0;
        if (!logged_cap) {
            fprintf(stderr, "ps5-drm-8bpc: intercettato drmGetCap(ADDFB2_MODIFIERS) -> forzato valore 0\n");
            logged_cap = 1;
        }
        return 0;
    }
    static orig_drmGetCap_fn real_fn = NULL;
    if (!real_fn) real_fn = (orig_drmGetCap_fn)dlsym(RTLD_NEXT, "drmGetCap");
    return real_fn ? real_fn(fd, capability, value) : -1;
}

drmModePlanePtr drmModeGetPlane(int fd, uint32_t plane_id) {
    static orig_drmModeGetPlane_fn real_fn = NULL;
    if (!real_fn) real_fn = (orig_drmModeGetPlane_fn)dlsym(RTLD_NEXT, "drmModeGetPlane");
    drmModePlanePtr plane = real_fn ? real_fn(fd, plane_id) : NULL;
    if (!plane || !plane->formats || plane->count_formats == 0) return plane;

    uint32_t removed = 0;
    uint32_t write_idx = 0;
    for (uint32_t i = 0; i < plane->count_formats; i++) {
        uint32_t fmt = plane->formats[i];
        if (fmt == DRM_FORMAT_XRGB2101010 || fmt == DRM_FORMAT_ARGB2101010 ||
            fmt == DRM_FORMAT_XBGR2101010 || fmt == DRM_FORMAT_ABGR2101010 ||
            fmt == DRM_FORMAT_RGBA1010102 || fmt == DRM_FORMAT_BGRA1010102) {
            removed++;
            continue;
        }
        plane->formats[write_idx++] = fmt;
    }
    if (removed > 0) {
        fprintf(stderr, "ps5-drm-8bpc: plane id=%u rimossi %u formati 10-bit (restano %u formati)\n",
                plane_id, removed, write_idx);
    }
    plane->count_formats = write_idx;
    return plane;
}
SHIM_EOF

    local cc_bin=""
    if command -v gcc >/dev/null 2>&1; then
        cc_bin="gcc"
    elif command -v clang >/dev/null 2>&1; then
        cc_bin="clang"
    elif [ -x "${cachy_mnt}/usr/bin/gcc" ]; then
        cc_bin="${cachy_mnt}/usr/bin/gcc"
    fi

    if [ -n "$cc_bin" ]; then
        if $cc_bin -shared -fPIC -O2 -Wall -Wextra -o "/tmp/libps5-drm-8bpc-$$.so" "${cachy_mnt}/usr/local/src/ps5-drm-8bpc.c" -ldl 2>/dev/null; then
            sudo cp -f "/tmp/libps5-drm-8bpc-$$.so" "${cachy_mnt}/usr/local/lib/libps5-drm-8bpc.so"
            sudo chmod 0755 "${cachy_mnt}/usr/local/lib/libps5-drm-8bpc.so"
            rm -f "/tmp/libps5-drm-8bpc-$$.so"
            log_success "Compilato e installato intercettore KMS 8bpc (libps5-drm-8bpc.so)."
        else
            log_warn "Compilazione di libps5-drm-8bpc.so non riuscita con $cc_bin."
        fi
    else
        log_warn "Nessun compilatore C trovato; generazione shim omessa."
    fi

    # 2. Configura gamescope-session-ps5 con auto-rilevamento risoluzione, verifica integrità Steam e rilevamento crash
    sudo mkdir -p "${cachy_mnt}/usr/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/bin/gamescope-session-ps5" >/dev/null
#!/bin/bash
# gamescope-session-ps5: launch Gamescope in DRM mode with dynamic display resolution detection
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
export LIBSEAT_BACKEND=logind
export STEAM_ENABLE_DECK_UI=1
export GAMESCOPE_FORCE_GRAB_CURSOR=1
export XDG_CURRENT_DESKTOP=gamescope
export XDG_SESSION_TYPE=wayland
export WLR_DRM_DEVICES="${PS5_DRM_DEVICE:-/dev/dri/card0}"
export GAMESCOPE_DISPLAY_SUPPORTS_HDR=0
export GAMESCOPE_DISPLAY_HDR_ENABLED=0
export GAMESCOPE_COLOR_MANAGEMENT_DISABLE=1
export STEAM_GAMESCOPE_HDR_SUPPORTED=0
export DXVK_HDR=0
export RADV_DEBUG=nodcc
export GAMESCOPE_COMPOSITE_FORCE=1
export WLR_DRM_NO_MODIFIERS=1

if [ -f /usr/local/lib/libps5-drm-8bpc.so ]; then
    export LD_PRELOAD="/usr/local/lib/libps5-drm-8bpc.so${LD_PRELOAD:+:$LD_PRELOAD}"
    ps5_log gamescope info "KMS 8bpc shim attivo: LD_PRELOAD=$LD_PRELOAD"
fi

LOG_FILE="${PS5_GAMESCOPE_LOG:-/home/steam/.gamescope.log}"

# Carica gli override prima di rilevare le modalita' del display.
[ -f /etc/ps5-gamescope.conf ] && source /etc/ps5-gamescope.conf
[ -f /home/steam/.config/gamescope/ps5-resolution.conf ] && source /home/steam/.config/gamescope/ps5-resolution.conf

# 0. Pre-check binari essenziali Gamescope e Steam (exit 70 in caso di assenza -> Fallback KDE)
if [ ! -x /usr/bin/gamescope ] || [ ! -x /usr/bin/steam ]; then
    echo "[$(date -Is)] PS5 Gamescope ERRORE CRITICO: /usr/bin/gamescope o /usr/bin/steam mancante/non eseguibile." >> "$LOG_FILE"
    ps5_log gamescope error "/usr/bin/gamescope o /usr/bin/steam mancante o non eseguibile (exit 70)"
    exit 70
fi

# 1. Attesa e scansione dello stato DRM (fino a 3s con intervalli di 0.5s per handshake HDMI)
DETECTED_CONN=""
DETECTED_W=""
DETECTED_H=""
DRM_CARD_FOUND=0

for i in {1..6}; do
    for c in /sys/class/drm/card*-*; do
        [ -f "$c/status" ] || continue
        DRM_CARD_FOUND=1
        if [ "$(cat "$c/status" 2>/dev/null)" = "connected" ]; then
            c_name="${c##*/}"
            c_port="${c_name#card*-}"
            if [ -f "$c/modes" ] && [ -s "$c/modes" ]; then
                top_mode=$(head -n 1 "$c/modes")
                w="${top_mode%x*}"
                h="${top_mode#*x}"
                if [ -n "$w" ] && [ -n "$h" ]; then
                    DETECTED_CONN="$c_port"
                    DETECTED_W="$w"
                    DETECTED_H="$h"
                    # Priorità per uscite video PS5 (DP-1 o HDMI-A-1)
                    case "$c_port" in
                        DP-1|HDMI-A-1) break 2 ;;
                    esac
                fi
            fi
        fi
    done
    [ -n "$DETECTED_W" ] && break
    sleep 0.5
done

if [ "$DRM_CARD_FOUND" -eq 0 ] && [ "${PS5_SKIP_DRM_CHECK:-0}" != "1" ]; then
    echo "[$(date -Is)] PS5 Gamescope ERRORE DRM: Nessun connettore DRM/KMS rilevato in /sys/class/drm." >> "$LOG_FILE"
    ps5_log gamescope error "Nessun connettore DRM/KMS rilevato in /sys/class/drm (exit 71)"
    exit 71
fi

# 2. Risoluzione e connettore finali (Override > Rilevamento automatico > Fallback standard 1080p60)
FINAL_OUTPUT_W="${PS5_OUTPUT_WIDTH:-${DETECTED_W:-1920}}"
FINAL_OUTPUT_H="${PS5_OUTPUT_HEIGHT:-${DETECTED_H:-1080}}"
FINAL_NESTED_W="${PS5_NESTED_WIDTH:-$FINAL_OUTPUT_W}"
FINAL_NESTED_H="${PS5_NESTED_HEIGHT:-$FINAL_OUTPUT_H}"
FINAL_CONN="${PS5_OUTPUT_CONN:-${DETECTED_CONN:-DP-1,HDMI-A-1}}"
FINAL_REFRESH="${PS5_REFRESH_RATE:-60}"

echo "[$(date -Is)] PS5 Gamescope Init: Connettore=${FINAL_CONN} (rilevato: ${DETECTED_CONN:-none}), Output=${FINAL_OUTPUT_W}x${FINAL_OUTPUT_H}, Nested=${FINAL_NESTED_W}x${FINAL_NESTED_H}, Refresh=${FINAL_REFRESH}" >> "$LOG_FILE"
ps5_log gamescope info "Init: Connettore=${FINAL_CONN} Output=${FINAL_OUTPUT_W}x${FINAL_OUTPUT_H}@${FINAL_REFRESH} Nested=${FINAL_NESTED_W}x${FINAL_NESTED_H}"

# 3. Controllo stato di Bootstrap/Integrità di Steam e sincronizzazione DHCP di Rete
STEAM_DIR="${PS5_STEAM_DIR:-/home/steam/.local/share/Steam}"
STEAM_INSTALLED_FLAG="${STEAM_DIR}/package/steam_client_ubuntu12.installed"

verify_and_repair_steam() {
    if [ -x /usr/local/bin/ps5-steam-verify-repair ]; then
        /usr/local/bin/ps5-steam-verify-repair "$STEAM_DIR" >> "$LOG_FILE" 2>&1 || true
        return 0
    fi
    local manifest line first_part rel_path exp_size full_path act_size
    for manifest in "${STEAM_DIR}"/package/*.installed; do
        [ -f "$manifest" ] || continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in SIGNATURE:*|OSVER=*|VERSION=*|SHA1=*) continue ;; esac
            rel_path=""
            exp_size=""
            case "$line" in
                *";"*","*)
                    first_part="${line%%;*}"
                    rel_path="${first_part%,*}"
                    exp_size="${first_part##*,}"
                    ;;
                *size=*)
                    rel_path="${line%%	*}"
                    exp_size="${line#*size=}"
                    exp_size="${exp_size%%	*}"
                    ;;
            esac
            case "$exp_size" in ""|-*) continue ;; esac
            full_path="${STEAM_DIR}/${rel_path}"
            act_size=$(stat -c %s "$full_path" 2>/dev/null || echo -1)
            if [ "$act_size" != "$exp_size" ]; then
                echo "[$(date -Is)] PS5 Gamescope: Rilevato file Steam troncato ($rel_path: $act_size != $exp_size), invalido $(basename "$manifest")." >> "$LOG_FILE"
                rm -f "$manifest" 2>/dev/null || true
                break
            fi
        done < "$manifest"
    done
}

is_steam_installed() {
    if [ -s "${STEAM_DIR}/ubuntu12_32/steam" ] || [ -s "$STEAM_INSTALLED_FLAG" ]; then
        return 0
    fi
    local inst_file
    for inst_file in "${STEAM_DIR}"/package/steam_client*.installed; do
        if [ -s "$inst_file" ]; then
            return 0
        fi
    done
    return 1
}

check_network() {
    if [ -n "${PS5_NET_CHECK_CMD:-}" ]; then
        eval "$PS5_NET_CHECK_CMD"
        return $?
    fi
    if ip route get 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

has_active_carrier() {
    local c
    for c in /sys/class/net/en*/carrier /sys/class/net/eth*/carrier /sys/class/net/wl*/carrier; do
        if [ -r "$c" ] && [ "$(cat "$c" 2>/dev/null)" = "1" ]; then
            return 0
        fi
    done
    return 1
}

wait_for_network() {
    local max_wait="${1:-15}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        if check_network; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    check_network
}

# Verifica e ripara eventuali librerie Steam troncate da spegnimenti forzati
verify_and_repair_steam

# Lascia attiva la verifica rapida delle dimensioni file di Steam all'avvio
STEAM_ARGS=(-gamepadui -steamos)

if is_steam_installed; then
    # Se il cavo Ethernet ha carrier attivo ma il DHCP sta ancora completando (~3-5s dal boot),
    # attendi fino a 6s così Steam parte già online senza falsi avvii offline.
    if ! check_network && has_active_carrier; then
        echo "[$(date -Is)] PS5 Gamescope: Carrier di rete rilevato, attesa completamento DHCP (max 6s)..." >> "$LOG_FILE"
        wait_for_network 6 || true
    fi
else
    echo "[$(date -Is)] PS5 Gamescope: Steam runtime package non ancora inizializzato (primo bootstrap richiesto). Attesa rete/DHCP fino a 15s..." >> "$LOG_FILE"
    if ! wait_for_network 15; then
        echo "[$(date -Is)] PS5 Gamescope ERRORE: Connessione di rete assente dopo 15s al primo avvio di Steam." >> "$LOG_FILE"
        echo "[$(date -Is)] Attivazione fallback automatico a KDE Plasma Desktop (exit 72)." >> "$LOG_FILE"
        mkdir -p /home/steam/.config
        cat << 'NOTIFY_EOF' > /home/steam/.config/ps5-steam-firstboot-alert.txt
ATTENZIONE: Al primo avvio, Steam necessita di una connessione internet attiva (cavo Ethernet o dongle Wi-Fi USB) per scaricare i componenti di gioco (~400 MB).
Configura la rete da questo Desktop KDE e avvia Steam una volta per completare l'installazione.
Successivamente potrai avviare la modalità Gaming Gamescope anche offline.
NOTIFY_EOF
        chown -R steam:steam /home/steam/.config 2>/dev/null || true
        exit 72
    fi
    echo "[$(date -Is)] Connessione attiva confermata: procedo con il primo bootstrap di Steam sotto Gamescope." >> "$LOG_FILE"
fi

# 5. Composizione argomenti Gamescope
STATS_DIR="/run/user/$(id -u 2>/dev/null || echo 1000)"
[ -d "$STATS_DIR" ] || STATS_DIR="/tmp"
STATS_FILE="${PS5_STATS_PATH:-$STATS_DIR/gamescope-stats.json}"

GAMESCOPE_CMD=(
    "${PS5_GAMESCOPE_EXEC:-/usr/bin/gamescope}"
    -W "$FINAL_OUTPUT_W"
    -H "$FINAL_OUTPUT_H"
    -w "$FINAL_NESTED_W"
    -h "$FINAL_NESTED_H"
    -r "$FINAL_REFRESH"
    --backend drm
    --prefer-output "$FINAL_CONN"
    --force-composition
    --disable-layers
    --disable-color-management
    --sdr-gamut-wideness 0
    --force-grab-cursor
    --stats-path "$STATS_FILE"
    -e
)

# Attesa 1s per rilascio master DRM
[ "${PS5_SKIP_DRM_SLEEP:-0}" = "1" ] || sleep 1

LOG_OFFSET=0
[ -f "$LOG_FILE" ] && LOG_OFFSET=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
CONSOLE_LOG="${STEAM_DIR}/logs/console-linux.txt"
CONSOLE_OFFSET=0
[ -f "$CONSOLE_LOG" ] && CONSOLE_OFFSET=$(wc -c < "$CONSOLE_LOG" 2>/dev/null || echo 0)

# Esporta DISPLAY e WAYLAND_DISPLAY creati da Gamescope nell'ambiente systemd --user / D-Bus
# prima di lanciare Steam, così xdg-desktop-portal-gtk si avvia senza "cannot open display:"
ps5_log gamescope info "Avvio processo gamescope con LD_PRELOAD=${LD_PRELOAD:-none}"
"${GAMESCOPE_CMD[@]}" -- /bin/sh -c '
    unset LD_PRELOAD
    export XDG_CURRENT_DESKTOP=gamescope
    export XDG_SESSION_TYPE=wayland
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
    else
        systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
    fi
    systemctl --user reset-failed xdg-desktop-portal.service xdg-desktop-portal-gtk.service 2>/dev/null || true
    "${PS5_STEAM_EXEC:-/usr/bin/steam}" "$@"
    exit $?
' -- "${STEAM_ARGS[@]}" >>"$LOG_FILE" 2>&1
GS_RC=$?

if [ "$GS_RC" -gt 128 ]; then
    sig_num=$((GS_RC - 128))
    ps5_log gamescope warn "Processo Gamescope terminato con segnale $sig_num (exit=$GS_RC)"
else
    ps5_log gamescope info "Processo Gamescope terminato con exit=$GS_RC"
fi

# Rileva crash fatali nativi di Steam (es. SIGBUS / SIGSEGV mascherati da steam.sh con exit 0)
CRASH_DETECTED=0
if [ -f "$LOG_FILE" ] && tail -c +$((LOG_OFFSET + 1)) "$LOG_FILE" 2>/dev/null | grep -qE "Bus error|Segmentation fault|core dumped|crash_20"; then
    CRASH_DETECTED=1
fi
if [ -f "$CONSOLE_LOG" ] && tail -c +$((CONSOLE_OFFSET + 1)) "$CONSOLE_LOG" 2>/dev/null | grep -qE "Bus error|Segmentation fault|core dumped|crash_20"; then
    CRASH_DETECTED=1
fi

if [ "$CRASH_DETECTED" -eq 1 ]; then
    echo "[$(date -Is)] PS5 Gamescope ERRORE CRITICO: Rilevato crash nativo di Steam (SIGBUS/SIGSEGV). Attivo fallback KDE (exit 73)." >> "$LOG_FILE"
    ps5_log gamescope error "Rilevato crash nativo di Steam (SIGBUS/SIGSEGV). Attivo fallback KDE (exit 73)"
    exit 73
fi

exit "$GS_RC"
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/bin/gamescope-session-ps5"

    # 2b. Se la directory Steam esiste sulla chiavetta, verifica e ripara subito eventuali librerie troncate
    if [ -d "${cachy_mnt}/home/steam/.local/share/Steam/package" ]; then
        log_info "Verifica integrità file client Steam su ${cachy_mnt}/home/steam/.local/share/Steam..."
        sudo "${cachy_mnt}/usr/local/bin/ps5-steam-verify-repair" "${cachy_mnt}/home/steam/.local/share/Steam" || true
    fi

    # 3. Assegna CAP_SYS_NICE a gamescope per permettere lo scheduling realtime ed evitare race condition
    if [ -f "${cachy_mnt}/usr/bin/gamescope" ]; then
        sudo setcap 'cap_sys_nice=eip' "${cachy_mnt}/usr/bin/gamescope" 2>/dev/null || true
        log_success "Assegnato cap_sys_nice a gamescope."
    fi

    log_success "Modulo Gamescope configurato con successo (auto-rilevamento DRM, auto-repair Steam e sync portali XDG attivo)."
    return 0
}

module_gamescope_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/usr/bin/gamescope-session-ps5" ] && \
       [ -f "${cachy_mnt}/usr/local/lib/libps5-drm-8bpc.so" ] && \
       [ -x "${cachy_mnt}/usr/local/bin/ps5-steam-verify-repair" ] && \
       [ -x "${cachy_mnt}/usr/local/bin/ps5-drm-setup" ] && \
       [ -x "${cachy_mnt}/usr/local/bin/ps5-video-diag" ] && \
       [ -f "${cachy_mnt}/usr/share/xdg-desktop-portal/gamescope-portals.conf" ]; then
        log_success "gamescope-session-ps5, libps5-drm-8bpc.so, ps5-steam-verify-repair, ps5-drm-setup, ps5-video-diag e gamescope-portals.conf configurati."
        return 0
    fi
    log_warn "gamescope-session-ps5, libps5-drm-8bpc.so, ps5-steam-verify-repair, ps5-drm-setup, ps5-video-diag o gamescope-portals.conf non presenti."
    return 1
}
