#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-all}"

# ── Install Go (shared by both modes) ───────────────────────────────────────

if [[ ! -x ./go/bin/go ]]; then
    curl -sfo go1.25.4.linux-amd64.tar.gz https://dl.google.com/go/go1.25.4.linux-amd64.tar.gz
    tar -xf go1.25.4.linux-amd64.tar.gz
fi
export PATH="$PWD/go/bin:$HOME/go/bin:$PATH"

# ── Get Final Computed DCAP Measurement ──────────────────────────────────────

if [[ "$MODE" == "computed" || "$MODE" == "all" ]]; then
    go install github.com/google/go-tdx-guest/tools/attest@91f9a52f36c7a6ce140d5f13a2fb4ca03b61349c
    curl -L -sfo dcap-qvl https://github.com/Phala-Network/dcap-qvl/releases/download/v0.3.12/dcap-qvl-linux-x86_64
    chmod +x ./dcap-qvl
    MESSAGE="Hello from TDX VM"
    PADDED_MESSAGE=$(printf "%-64s" "$MESSAGE")
    REPORT_DATA_HEX=$(echo -n "$PADDED_MESSAGE" | xxd -p | tr -d '\n')
    attest -in "$REPORT_DATA_HEX" -inform hex -out /tmp/tdx_attestation.bin -outform bin -v
    ./dcap-qvl decode /tmp/tdx_attestation.bin | jq .report.TD10 > /tmp/dcap-computed.json
fi

# ── Get raw measurements ────────────────────────────────────────────────────

if [[ "$MODE" == "raw" || "$MODE" == "all" ]]; then
    go install github.com/canonical/tcglog-parser/tcglog-dump@62c1fa25dffb00565d97fa7ec840d2c8cabcee9d
    perl -0777 -pe 's/\xFF+$//' /sys/firmware/acpi/tables/data/CCEL > /tmp/ccel.bin
    tcglog-dump -v /tmp/ccel.bin > /tmp/dcap-raw
fi
