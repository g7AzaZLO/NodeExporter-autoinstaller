#!/usr/bin/env bash

# Do not change shell options or exit the caller's shell when sourced.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'Download this script and run it with sudo bash; do not source it.\n' >&2
    return 1
fi
set -Eeuo pipefail
umask 022

VERSION=1.12.1
LISTEN_ADDRESS=''
SERVICE=exporterd.service
BINARY=/usr/local/bin/node_exporter
UNIT=/etc/systemd/system/exporterd.service
CONFIG=/etc/default/exporterd
SERVICE_USER=node_exporter
work_dir=''
staged_binary=''
staged_unit=''
staged_config=''
changed=0
was_active=0
was_enabled=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: sudo bash NodeExporter-auto-install.sh [OPTIONS]

  --version X.Y.Z          Install this exact release (default: 1.12.1).
  --listen-address IP:PORT Bind to an IPv4 or [IPv6] address and port.
                          Preserve /etc/default/exporterd when omitted;
                          a fresh install listens on 127.0.0.1:9100.
  -h, --help              Show this help.

Requires Linux, a running systemd manager, root, curl, tar, gzip, sha256sum,
flock and the standard user/account utilities. No firewall rules are changed.
EOF
}

while (($#)); do
    case "$1" in
        --version|--listen-address)
            (($# >= 2)) || die "Missing value for $1"
            if [[ $1 == --version ]]; then VERSION=$2; else LISTEN_ADDRESS=$2; fi
            [[ -n $2 ]] || die "Empty value for $1"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Version must be X.Y.Z.'
[[ $(uname -s) == Linux ]] || die 'Only Linux is supported.'
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    armv6l) arch=armv6 ;;
    i386|i486|i586|i686) arch=386 ;;
    ppc64le|s390x|riscv64) arch=$(uname -m) ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac
((EUID == 0)) || die 'Run with sudo bash NodeExporter-auto-install.sh.'
for command in curl tar gzip sha256sum flock install mktemp awk cp mv rm chmod sleep getent useradd systemctl; do
    command -v "$command" >/dev/null || die "Required command not found: $command"
done
systemctl show --property=Version --value >/dev/null 2>&1 || die 'A running systemd manager is required.'
install -d -m 0700 /run/node-exporter-autoinstaller
exec 9>/run/node-exporter-autoinstaller/lock
flock -n 9 || die 'Another node_exporter installation is running.'

for file in "$BINARY" "$UNIT" "$CONFIG"; do
    [[ ! -L $file ]] || die "Refusing to replace a symbolic link: $file"
    [[ ! -e $file || -f $file ]] || die "Not a regular file: $file"
done

if [[ -z $LISTEN_ADDRESS && -f $CONFIG ]]; then
    LISTEN_ADDRESS=$(awk -F= '$1 == "LISTEN_ADDRESS" {print substr($0, index($0, "=") + 1)}' "$CONFIG")
    [[ -n $LISTEN_ADDRESS ]] || die "No LISTEN_ADDRESS found in $CONFIG"
fi
LISTEN_ADDRESS=${LISTEN_ADDRESS:-127.0.0.1:9100}
if [[ $LISTEN_ADDRESS =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:([0-9]{1,5})$ ]]; then
    port=${LISTEN_ADDRESS##*:}
    host=${LISTEN_ADDRESS%:*}
    IFS=. read -r -a octets <<<"$host"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || die 'Invalid IPv4 address.'
    done
    [[ $host != 0.0.0.0 ]] || host=127.0.0.1
elif [[ $LISTEN_ADDRESS =~ ^\[([[:xdigit:]:]+)\]:([0-9]{1,5})$ ]]; then
    host="[${BASH_REMATCH[1]}]"
    port=${BASH_REMATCH[2]}
    [[ $host != '[::]' ]] || host='[::1]'
else
    die 'Use an IPv4 address:port or [IPv6 address]:port; hostnames and extra arguments are not accepted.'
fi
((10#$port >= 1 && 10#$port <= 65535)) || die 'Port must be between 1 and 65535.'
port=$((10#$port))

# Invoked indirectly by the EXIT trap; ShellCheck 0.9 marks this callback unreachable.
# shellcheck disable=SC2317
cleanup() {
    local status=$? rollback_failed=0 file
    trap - EXIT
    set +e
    if ((status != 0 && changed)); then
        printf 'Installation failed; restoring previous binary, configuration and service.\n' >&2
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        if ((was_enabled == 0)); then
            systemctl disable "$SERVICE" >/dev/null 2>&1 || rollback_failed=1
        fi
        for file in "$BINARY" "$UNIT" "$CONFIG"; do
            if [[ -f $work_dir/backup${file} ]]; then
                cp -p -- "$work_dir/backup${file}" "$file" || rollback_failed=1
            else
                rm -f -- "$file" || rollback_failed=1
            fi
        done
        systemctl daemon-reload || rollback_failed=1
        if ((was_enabled)); then
            systemctl enable "$SERVICE" >/dev/null 2>&1 || rollback_failed=1
        fi
        if ((was_active)); then systemctl start "$SERVICE" || rollback_failed=1; fi
        if ((rollback_failed)); then
            printf 'Rollback was incomplete; inspect systemctl status %s. Backups kept in %s\n' "$SERVICE" "$work_dir" >&2
        fi
    fi
    for file in "$staged_binary" "$staged_unit" "$staged_config"; do
        [[ -z $file ]] || rm -f -- "$file"
    done
    if [[ -n $work_dir ]] && ((rollback_failed == 0)); then rm -rf -- "$work_dir"; fi
    exit "$status"
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

work_dir=$(mktemp -d /tmp/node-exporter-install.XXXXXXXX)
distribution="node_exporter-${VERSION}.linux-${arch}"
archive="${distribution}.tar.gz"
base_url="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}"
download() {
    curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 10 --max-time 180 --proto '=https' --proto-redir '=https' \
        --output "$2" "$1"
}
printf 'Downloading node_exporter %s for linux-%s...\n' "$VERSION" "$arch"
download "$base_url/$archive" "$work_dir/$archive"
download "$base_url/sha256sums.txt" "$work_dir/sha256sums.txt"
awk -v archive="$archive" '$2 == archive {print}' "$work_dir/sha256sums.txt" >"$work_dir/checksum"
[[ $(awk 'END {print NR}' "$work_dir/checksum") == 1 ]] || die 'Release has no unique checksum for this archive.'
(cd "$work_dir" && sha256sum --check --status checksum) || die 'Archive SHA-256 verification failed.'
tar --extract --gzip --file "$work_dir/$archive" --directory "$work_dir" \
    --no-same-owner --no-same-permissions "$distribution/node_exporter"

if getent passwd "$SERVICE_USER" >/dev/null; then
    account=$(getent passwd "$SERVICE_USER")
    IFS=: read -r _ _ account_uid _ _ _ account_shell <<<"$account"
    ((account_uid != 0)) || die "$SERVICE_USER must not have UID 0."
    case "$account_shell" in */nologin|*/false) ;; *) die "$SERVICE_USER must be a non-login service account." ;; esac
else
    nologin_path=$(command -v nologin || true)
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell "${nologin_path:-/bin/false}" "$SERVICE_USER"
fi

cat >"$work_dir/exporterd.service" <<'EOF'
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
EnvironmentFile=/etc/default/exporterd
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${LISTEN_ADDRESS}
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
systemctl is-active --quiet "$SERVICE" && was_active=1
systemctl is-enabled --quiet "$SERVICE" && was_enabled=1
for file in "$BINARY" "$UNIT" "$CONFIG"; do
    if [[ -f $file ]]; then
        install -d -m 0700 "$work_dir/backup${file%/*}"
        cp -p -- "$file" "$work_dir/backup${file}"
    fi
done
install -d -m 0755 /usr/local/bin /etc/default
staged_binary=$(mktemp /usr/local/bin/.node_exporter.XXXXXXXX)
staged_unit=$(mktemp /etc/systemd/system/.exporterd.XXXXXXXX)
staged_config=$(mktemp /etc/default/.exporterd.XXXXXXXX)
install -m 0755 "$work_dir/$distribution/node_exporter" "$staged_binary"
version_output=$("$staged_binary" --version 2>&1)
[[ $version_output == *"version $VERSION "* || $version_output == *"version $VERSION ("* ]] || die 'Downloaded binary reports an unexpected version.'
install -m 0644 "$work_dir/exporterd.service" "$staged_unit"
if [[ -f $CONFIG ]]; then
    # Preserve comments and any other administrator settings.
    awk -v address="$LISTEN_ADDRESS" '$0 !~ /^LISTEN_ADDRESS=/ {print} END {print "LISTEN_ADDRESS=" address}' "$CONFIG" >"$staged_config"
else
    printf '# Managed by NodeExporter-autoinstaller; edit or use --listen-address.\nLISTEN_ADDRESS=%s\n' "$LISTEN_ADDRESS" >"$staged_config"
fi
if [[ -f $CONFIG ]]; then
    chmod --reference="$CONFIG" "$staged_config"
else
    chmod 0644 "$staged_config"
fi
changed=1
mv -f -- "$staged_binary" "$BINARY"
mv -f -- "$staged_unit" "$UNIT"
mv -f -- "$staged_config" "$CONFIG"
systemctl daemon-reload
[[ $(systemctl show "$SERVICE" --property=User --value) == "$SERVICE_USER" ]] || die 'A systemd override changes the service user; review existing drop-in files.'
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

url="http://${host}:${port}/metrics"
for ((attempt = 0; attempt < 30; attempt++)); do
    if systemctl is-active --quiet "$SERVICE" && \
        curl --fail --silent --show-error --noproxy '*' --max-time 3 "$url" >"$work_dir/metrics" 2>/dev/null && \
        awk -v version="$VERSION" '/^node_exporter_build_info\{/ && index($0, "version=\"" version "\"") {found=1} END {exit !found}' "$work_dir/metrics"; then
        printf 'Installed node_exporter %s. Service: %s; metrics: %s\n' "$VERSION" "$SERVICE" "$url"
        printf 'Firewall unchanged. For remote scraping, use a private listen address and allow only your Prometheus server.\n'
        exit 0
    fi
    sleep 1
done
die "Service did not expose metrics for version $VERSION. Inspect: journalctl -u $SERVICE -n 50"
