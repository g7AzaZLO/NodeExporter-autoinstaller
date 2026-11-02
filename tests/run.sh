#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d)
trap 'rm -rf -- "$fixture_dir"' EXIT
version=1.12.1
case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) printf 'Integration tests require amd64 or arm64.\n' >&2; exit 1 ;;
esac
archive="node_exporter-${version}.linux-${arch}.tar.gz"
base_url="https://github.com/prometheus/node_exporter/releases/download/v${version}"
for file in "$archive" sha256sums.txt; do
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 180 \
        --proto '=https' --proto-redir '=https' "$base_url/$file" -o "$fixture_dir/$file"
done
awk -v archive="$archive" '$2 == archive {print}' "$fixture_dir/sha256sums.txt" >"$fixture_dir/checksum"
test "$(awk 'END {print NR}' "$fixture_dir/checksum")" = 1
(cd "$fixture_dir" && sha256sum --check checksum)
build_args=()
if [[ -n ${CODEX_PROXY_CERT:-} ]]; then
    build_args+=(--secret "id=proxy_ca,src=$CODEX_PROXY_CERT")
fi
docker build "${build_args[@]}" -t node-exporter-installer-tests -f tests/Dockerfile .
# Root installation is confined to this disposable container, with no network
# and no host service/account/firewall mounts. Only fixtures are mounted, read-only.
docker run --rm --network none --mount "type=bind,src=$fixture_dir,dst=/fixtures,readonly" \
    node-exporter-installer-tests
