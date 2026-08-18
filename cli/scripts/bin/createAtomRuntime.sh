#!/bin/bash
#
# createAtomRuntime.sh
#
# Convenience wrapper that installs and stands up a Boomi ATOM runtime on an
# Ubuntu host. It uses the boomi_runtime_installer.sh bootstrap flow from the
# feature/snmx-install-token branch, which adds support for authenticating
# with a pre-generated Boomi installToken instead of an AtomSphere API token.
#
# Usage:
#   sudo ./createAtomRuntime.sh atomName=<name> accountId=<accountId> installToken=<token>
#   -- or, using the classic AtomSphere API token instead --
#   sudo ./createAtomRuntime.sh atomName=<name> accountId=<accountId> boomiAtmosphereToken=BOOMI_TOKEN.<user>:<apiToken>
#
# Run with help=1 (or no arguments) to see the full list of options.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./createAtomRuntime.sh atomName=<name> accountId=<accountId> (installToken=<token> | boomiAtmosphereToken=<BOOMI_TOKEN...>) [option=value ...]

Required:
  atomName                Name to give the Atom
  accountId               Boomi account ID to install the Atom under
  installToken             Pre-generated Boomi install token (preferred - skips AtomSphere API auth)
    -- or --
  boomiAtmosphereToken     AtomSphere API token, format BOOMI_TOKEN.<user>:<apiToken>

Optional (defaults shown):
  platform=                     Cloud platform hint: aws|azure|gcp|"" (default: "")
  boomiEnv=                     Environment name to attach the Atom to (default: "" = not attached)
  boomiClassification=          TEST|PROD - required if boomiEnv is set
  purgeHistoryDays=14
  maxMem=4g
  installDir=/mnt/boomi
  workDir=/usr/local/boomi/work
  tmpDir=/usr/local/boomi/tmp
  client=
  group=
  efsMount=                     EFS filesystem id to mount (default: "" = no EFS mount)
  gitBranch=feature/snmx-install-token   Repo branch used to install (must contain installToken support)

Example:
  sudo ./createAtomRuntime.sh atomName=MyAtom01 accountId=myaccount-ABCDEF installToken=abc123XYZ
EOF
  exit 1
}

if [ "$#" -eq 0 ]; then
  usage
fi

# ---- defaults ----
platform=""
boomiEnv=""
boomiClassification=""
purgeHistoryDays="14"
maxMem="4g"
installDir="/mnt/boomi"
workDir="/usr/local/boomi/work"
tmpDir="/usr/local/boomi/tmp"
client=""
group=""
efsMount=""
gitBranch="feature/snmx-install-token"
installToken=""
boomiAtmosphereToken=""
atomName=""
accountId=""

# ---- parse KEY=VALUE arguments ----
for ARG in "$@"; do
  case "$ARG" in
    help|--help|-h|help=*)
      usage
      ;;
    *=*)
      KEY="${ARG%%=*}"
      VALUE="${ARG#*=}"
      case "$KEY" in
        atomName|accountId|installToken|boomiAtmosphereToken|platform|boomiEnv|boomiClassification|purgeHistoryDays|maxMem|installDir|workDir|tmpDir|client|group|efsMount|gitBranch)
          printf -v "$KEY" '%s' "$VALUE"
          ;;
        *)
          echo "Unknown parameter: $KEY" >&2
          usage
          ;;
      esac
      ;;
    *)
      echo "Invalid argument: $ARG (expected KEY=VALUE)" >&2
      usage
      ;;
  esac
done

# ---- validate required parameters ----
MISSING=""
[ -z "${atomName}" ] && MISSING="${MISSING} atomName"
[ -z "${accountId}" ] && MISSING="${MISSING} accountId"

if [ -n "${MISSING}" ]; then
  echo "ERROR: Missing required parameter(s):${MISSING}" >&2
  usage
fi

if [ -z "${installToken}" ] && [ -z "${boomiAtmosphereToken}" ]; then
  echo "ERROR: You must provide either installToken=<token> or boomiAtmosphereToken=BOOMI_TOKEN.<user>:<apiToken>" >&2
  usage
fi

if [ -n "${boomiAtmosphereToken}" ] && [[ "${boomiAtmosphereToken}" != BOOMI_TOKEN.* ]]; then
  echo "ERROR: boomiAtmosphereToken must start with 'BOOMI_TOKEN.' - see https://help.boomi.com/bundle/integration/page/int-AtomSphere_API_Tokens_page.html" >&2
  exit 1
fi

if [ -n "${boomiEnv}" ] && [ -z "${boomiClassification}" ]; then
  echo "ERROR: boomiClassification=<TEST|PROD> is required when boomiEnv is set" >&2
  usage
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

export atomType="ATOM"
export atomName accountId installToken boomiAtmosphereToken platform boomiEnv boomiClassification
export purgeHistoryDays maxMem installDir workDir tmpDir client group efsMount gitBranch
export boomiAccountId="${accountId}"

echo "=== Boomi ATOM runtime setup ==="
echo "Atom Name    : ${atomName}"
echo "Account Id   : ${accountId}"
if [ -n "${installToken}" ]; then
  echo "Auth mode    : installToken (AtomSphere API authentication skipped)"
else
  echo "Auth mode    : boomiAtmosphereToken (AtomSphere API)"
fi
echo "Environment  : ${boomiEnv:-<none>}"
echo "Repo branch  : ${gitBranch}"
echo "================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/boomi_runtime_installer.sh" ]; then
  echo "Using local boomi_runtime_installer.sh from ${SCRIPT_DIR}"
  INSTALLER="${SCRIPT_DIR}/boomi_runtime_installer.sh"
else
  echo "Downloading boomi_runtime_installer.sh from branch '${gitBranch}'..."
  TMP_DIR_INSTALLER="$(mktemp -d)"
  INSTALLER="${TMP_DIR_INSTALLER}/boomi_runtime_installer.sh"
  curl -fsSL "https://raw.githubusercontent.com/UnitedTechnoCloud/boomiinstall-cli/${gitBranch}/cli/scripts/bin/boomi_runtime_installer.sh" -o "${INSTALLER}"
  chmod +x "${INSTALLER}"
fi

bash "${INSTALLER}"
