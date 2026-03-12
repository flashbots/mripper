#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: mripper.sh [OPTIONS] <COMMAND|SCRIPT_PATH> [-- EXTRA_GCLOUD_ARGS...]

Deploy a confidential compute TDX VM, execute a command over SSH, print output, and delete the instance.

The command to execute can be:
  - An inline command string:  ./mripper.sh --project my-proj ... 'echo hello'
  - A path to a local script:  ./mripper.sh --project my-proj ... ./my-script.sh

Required options:
  --machine-type TYPE    GCP machine type (e.g. n2d-standard-2)
  --project PROJECT      GCP project ID
  --image IMAGE          Full image path (e.g. projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20240126)
  --zone ZONE            GCP zone (e.g. us-central1-a)
  --network NETWORK      VPC network
  --subnet SUBNET        VPC subnet

Optional:
  --name NAME            Instance name (default: auto-generated mripper-<timestamp>)
  --sudo                 Execute the command/script with sudo
  -h, --help             Show this help

Everything after '--' is passed directly to gcloud compute instances create.

Examples:
  ./mripper.sh --project my-proj --machine-type n2d-standard-2 --image projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20240126 --zone us-central1-a --network default --subnet default 'echo hello world'

  ./mripper.sh --project my-proj --machine-type n2d-standard-2 --image projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20240126 --zone us-central1-a --network default --subnet default ./run-remote.sh

  ./mripper.sh --project my-proj --machine-type n2d-standard-2 --image projects/ubuntu-os-cloud/global/images/ubuntu-2204-jammy-v20240126 --zone us-central1-a --network default --subnet default 'echo test' -- --min-cpu-platform="AMD Milan"
USAGE
    exit "${1:-0}"
}

# ── Parse arguments ──────────────────────────────────────────────────────────

INSTANCE_NAME=""
MACHINE_TYPE=""
PROJECT=""
IMAGE=""
ZONE=""
NETWORK=""
SUBNET=""
COMMAND_ARG=""
USE_SUDO=false
EXTRA_GCLOUD_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage 0
            ;;
        --machine-type)
            MACHINE_TYPE="$2"; shift 2 ;;
        --project)
            PROJECT="$2"; shift 2 ;;
        --image)
            IMAGE="$2"; shift 2 ;;
        --zone)
            ZONE="$2"; shift 2 ;;
        --network)
            NETWORK="$2"; shift 2 ;;
        --subnet)
            SUBNET="$2"; shift 2 ;;
        --name)
            INSTANCE_NAME="$2"; shift 2 ;;
        --sudo)
            USE_SUDO=true; shift ;;
        --)
            shift
            EXTRA_GCLOUD_ARGS=("$@")
            break
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            usage 1
            ;;
        *)
            # Positional arg = command or script path
            if [[ -n "$COMMAND_ARG" ]]; then
                echo "Error: multiple commands specified" >&2
                usage 1
            fi
            COMMAND_ARG="$1"
            shift
            ;;
    esac
done

# ── Validate required arguments ──────────────────────────────────────────────

missing=()
[[ -z "$MACHINE_TYPE" ]] && missing+=(--machine-type)
[[ -z "$PROJECT" ]]      && missing+=(--project)
[[ -z "$IMAGE" ]]        && missing+=(--image)
[[ -z "$ZONE" ]]         && missing+=(--zone)
[[ -z "$NETWORK" ]]      && missing+=(--network)
[[ -z "$SUBNET" ]]       && missing+=(--subnet)
[[ -z "$COMMAND_ARG" ]]  && missing+=("COMMAND|SCRIPT_PATH")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required arguments: ${missing[*]}" >&2
    echo >&2
    usage 1
fi

# ── Auto-generate instance name if not provided ─────────────────────────────

if [[ -z "$INSTANCE_NAME" ]]; then
    INSTANCE_NAME="mripper-$(date +%s)"
fi

FIREWALL_RULE="mripper-allow-ssh-${INSTANCE_NAME}"

# ── Determine if COMMAND_ARG is a local script file ──────────────────────────

IS_SCRIPT=false
if [[ -f "$COMMAND_ARG" ]]; then
    IS_SCRIPT=true
fi

# ── Cleanup: always delete the instance on exit ──────────────────────────────

cleanup() {
    echo ""
    echo ">> Deleting firewall rule ${FIREWALL_RULE}..."
    gcloud compute firewall-rules delete "$FIREWALL_RULE" \
        --project="$PROJECT" \
        --quiet 2>/dev/null || true
    echo ">> Deleting instance ${INSTANCE_NAME}..."
    gcloud compute instances delete "$INSTANCE_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet 2>/dev/null || true
}
trap cleanup EXIT

# ── Create the VM ────────────────────────────────────────────────────────────

echo ">> Creating instance ${INSTANCE_NAME}..."
gcloud compute instances create "$INSTANCE_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image="$IMAGE" \
    --network="$NETWORK" \
    --subnet="$SUBNET" \
    --confidential-compute-type=TDX \
    --maintenance-policy=TERMINATE \
    --no-shielded-secure-boot \
    --no-shielded-vtpm \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-balanced \
    --tags="$INSTANCE_NAME" \
    "${EXTRA_GCLOUD_ARGS[@]}"

# ── Create firewall rule to allow SSH ────────────────────────────────────────

echo ">> Creating firewall rule ${FIREWALL_RULE}..."
gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --project="$PROJECT" \
    --network="$NETWORK" \
    --allow=tcp:22 \
    --target-tags="$INSTANCE_NAME" \
    --direction=INGRESS

# ── Wait for SSH to become available ─────────────────────────────────────────

echo ">> Waiting for SSH to become available..."
for i in $(seq 1 60); do
    if gcloud compute ssh "$INSTANCE_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --command="true" \
        --quiet 2>/dev/null; then
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "Error: timed out waiting for SSH after 60 attempts" >&2
        exit 1
    fi
    sleep 5
done

# ── Execute command on the VM ────────────────────────────────────────────────

if [[ "$IS_SCRIPT" == true ]]; then
    echo ">> Uploading script $(basename "$COMMAND_ARG")..."
    REMOTE_SCRIPT="/tmp/mripper-script-$(basename "$COMMAND_ARG")"
    gcloud compute scp "$COMMAND_ARG" "${INSTANCE_NAME}:${REMOTE_SCRIPT}" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet

    SUDO_PREFIX=""
    [[ "$USE_SUDO" == true ]] && SUDO_PREFIX="sudo "

    echo ">> Executing script on ${INSTANCE_NAME}..."
    gcloud compute ssh "$INSTANCE_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --command="chmod +x '${REMOTE_SCRIPT}' && ${SUDO_PREFIX}'${REMOTE_SCRIPT}'"
else
    SUDO_PREFIX=""
    [[ "$USE_SUDO" == true ]] && SUDO_PREFIX="sudo "

    echo ">> Executing command on ${INSTANCE_NAME}..."
    gcloud compute ssh "$INSTANCE_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --command="${SUDO_PREFIX}${COMMAND_ARG}"
fi
