#!/bin/bash
#
# createAtomService.sh
#
# Recovery/setup script to (re)create and start the systemd atom.service unit
# on a host where the Boomi Atom binaries are already installed but the
# service was never registered (e.g. installBoomiService.sh was skipped or
# failed during the original install). Safe to re-run.
#
# Usage:
#   sudo ./createAtomService.sh atomName=<name> [serviceUserName=boomi] [mountPoint=/mnt/boomi] [atomHome=<path>]
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./createAtomService.sh atomName=<name> [serviceUserName=boomi] [mountPoint=/mnt/boomi] [atomHome=<path>]

Required:
  atomName          Name of the already-installed Atom

Optional:
  serviceUserName   OS user the atom runs as (default: boomi)
  mountPoint        Mount point atom.service depends on being available (default: /mnt/boomi)
  atomHome          Full path to the Atom install dir. If omitted, it is derived from
                     ATOM_HOME in /home/<serviceUserName>/.profile, falling back to
                     <mountPoint>/Atom_<atomName with - replaced by _>

Example:
  sudo ./createAtomService.sh atomName=MyAtom01 mountPoint=/data/boomi
EOF
  exit 1
}

if [ "$#" -eq 0 ]; then
  usage
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

atomName=""
serviceUserName="boomi"
mountPoint="/data/boomi"
atomHome=""

for ARG in "$@"; do
  case "$ARG" in
    help|--help|-h)
      usage
      ;;
    *=*)
      KEY="${ARG%%=*}"
      VALUE="${ARG#*=}"
      case "$KEY" in
        atomName|serviceUserName|mountPoint|atomHome)
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

if [ -z "${atomName}" ]; then
  echo "ERROR: atomName is required" >&2
  usage
fi

# Try to pick up ATOM_HOME from the existing profile if atomHome wasn't given explicitly.
if [ -z "${atomHome}" ] && [ -f "/home/${serviceUserName}/.profile" ]; then
  # shellcheck disable=SC1091
  set +u
  source "/home/${serviceUserName}/.profile"
  set -u
  atomHome="${ATOM_HOME:-}"
fi

if [ -z "${atomHome}" ]; then
  normalizedName="$(echo "${atomName}" | sed -e 's/-/_/g')"
  atomHome="${mountPoint}/Atom_${normalizedName}"
fi

if [ ! -x "${atomHome}/bin/atom" ]; then
  echo "ERROR: ${atomHome}/bin/atom not found or not executable. Check atomName/atomHome/serviceUserName." >&2
  exit 1
fi

echo "Using atomHome=${atomHome}, serviceUserName=${serviceUserName}, mountPoint=${mountPoint}"

ln -sf "${atomHome}/bin/atom" /usr/local/bin/atom

for f in start-atom.sh stop-atom.sh; do
  if [ ! -f "/home/${serviceUserName}/${f}" ]; then
    echo "ERROR: /home/${serviceUserName}/${f} is missing." >&2
    echo "       Copy it from cli/scripts/home/${f} in this repo to /home/${serviceUserName}/ before continuing." >&2
    exit 1
  fi
done
chmod +x "/home/${serviceUserName}/start-atom.sh" "/home/${serviceUserName}/stop-atom.sh"

echo "Creating /etc/systemd/system/atom.service ..."
cat <<EOF >/etc/systemd/system/atom.service
[Unit]
Description=Boomi ${atomName}
After=network.target
RequiresMountsFor="${mountPoint}"
[Service]
User=${serviceUserName}
WorkingDirectory=/home/${serviceUserName}
PassEnvironment=JAVA_HOME
ExecStart="/home/${serviceUserName}/start-atom.sh"
ExecStop="/home/${serviceUserName}/stop-atom.sh"
Type=forking
TimeoutStartSec=600
Restart=always
[Install]
WantedBy=multi-user.target
EOF

echo "Setting up JMX remote credentials (edit /etc/jmxremote/jmxremote.password afterwards - the default is a placeholder and must be changed for production use)..."
mkdir -vp /etc/jmxremote
if [ ! -f /etc/jmxremote/jmxremote.password ]; then
  cat <<'EOF' >/etc/jmxremote/jmxremote.password
monitorRole Password
EOF
fi
if [ ! -f /etc/jmxremote/jmxremote.access ]; then
  cat <<'EOF' >/etc/jmxremote/jmxremote.access
monitorRole readonly
EOF
fi
chmod -R 0600 /etc/jmxremote
chown -R "${serviceUserName}:${serviceUserName}" /etc/jmxremote/jmxremote.*

echo "Registering and starting atom.service ..."
systemctl daemon-reload
systemctl enable atom
systemctl start atom
sleep 3
systemctl status atom --no-pager || true
if systemctl is-active --quiet atom; then
  echo "atom.service is running."
else
  echo "WARNING: atom.service did not start. Check 'journalctl -u atom -n 100 --no-pager' for details." >&2
  exit 1
fi
