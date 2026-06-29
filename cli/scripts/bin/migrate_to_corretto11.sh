#!/bin/bash
# =============================================================================
# migrate_to_corretto11.sh
# Migrates an existing Boomi Atom/Molecule/Cloud/Gateway from OpenJDK to
# Amazon Corretto 11 on Amazon Linux.
#
# Usage:
#   sudo bash migrate_to_corretto11.sh <atomType> <atomName>
#
# Examples:
#   sudo bash migrate_to_corretto11.sh ATOM      MyAtom
#   sudo bash migrate_to_corretto11.sh MOLECULE  MyMolecule
#   sudo bash migrate_to_corretto11.sh CLOUD     MyCloud
#   sudo bash migrate_to_corretto11.sh GATEWAY   MyGateway
# =============================================================================

set -e

ATOM_TYPE="${1}"
ATOM_NAME="${2}"
INSTALL_BASE="/mnt/boomi"
BOOMI_USER="boomi"

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [ -z "$ATOM_TYPE" ] || [ -z "$ATOM_NAME" ]; then
    echo "ERROR: Usage: sudo bash $0 <atomType> <atomName>"
    echo "       atomType must be one of: ATOM, MOLECULE, CLOUD, GATEWAY"
    exit 1
fi

case "$ATOM_TYPE" in
    ATOM)    ATOM_HOME="${INSTALL_BASE}/Atom_${ATOM_NAME}" ;;
    MOLECULE) ATOM_HOME="${INSTALL_BASE}/Molecule_${ATOM_NAME}" ;;
    CLOUD)   ATOM_HOME="${INSTALL_BASE}/Cloud_${ATOM_NAME}" ;;
    GATEWAY) ATOM_HOME="${INSTALL_BASE}/Gateway_${ATOM_NAME}" ;;
    *)
        echo "ERROR: Unknown atomType '${ATOM_TYPE}'. Must be ATOM, MOLECULE, CLOUD, or GATEWAY."
        exit 1
        ;;
esac

if [ ! -d "$ATOM_HOME" ]; then
    echo "ERROR: Atom home directory not found: $ATOM_HOME"
    exit 1
fi

echo "=================================================================="
echo " Boomi Runtime Corretto 11 Migration"
echo " Type : $ATOM_TYPE"
echo " Name : $ATOM_NAME"
echo " Home : $ATOM_HOME"
echo "=================================================================="

# ---------------------------------------------------------------------------
# Step 1 — Install Amazon Corretto 11
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] Installing Amazon Corretto 11..."
if rpm -q java-11-amazon-corretto &>/dev/null; then
    echo "         Corretto 11 is already installed. Skipping."
else
    yum install -y java-11-amazon-corretto
    echo "         Corretto 11 installed."
fi

# ---------------------------------------------------------------------------
# Step 2 — Discover actual Corretto installation path
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] Discovering Corretto 11 installation path..."

CORRETTO_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "*amazon-corretto*" 2>/dev/null | head -1)

if [ -z "$CORRETTO_HOME" ]; then
    echo "         Falling back: searching via 'alternatives'..."
    JAVA_BIN=$(alternatives --list 2>/dev/null | grep java | awk '{print $3}' | grep corretto | head -1)
    if [ -n "$JAVA_BIN" ]; then
        CORRETTO_HOME=$(dirname $(dirname $JAVA_BIN))
    fi
fi

if [ -z "$CORRETTO_HOME" ] || [ ! -f "${CORRETTO_HOME}/bin/java" ]; then
    echo "ERROR: Could not locate Corretto 11 JDK. Please verify installation."
    echo "       Run: ls -la /usr/lib/jvm/"
    exit 1
fi

echo "         Found Corretto at: $CORRETTO_HOME"
${CORRETTO_HOME}/bin/java -version

# ---------------------------------------------------------------------------
# Step 3 — Stop the Boomi runtime
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] Stopping Boomi runtime..."
if sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" status 2>/dev/null | grep -qi "running"; then
    sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" stop
    echo "         Waiting for runtime to fully stop (max 120s)..."
    STOP_TIMEOUT=120
    STOP_ELAPSED=0
    while sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" status 2>/dev/null | grep -qi "running"; do
        if [ $STOP_ELAPSED -ge $STOP_TIMEOUT ]; then
            echo "ERROR: Runtime did not stop within ${STOP_TIMEOUT}s. Aborting."
            echo "       Check logs at: ${ATOM_HOME}/bin/atom.log"
            exit 1
        fi
        sleep 5
        STOP_ELAPSED=$((STOP_ELAPSED + 5))
        echo "         Still stopping... (${STOP_ELAPSED}s)"
    done
    echo "         Runtime stopped after ${STOP_ELAPSED}s."
else
    echo "         Runtime is not running. Continuing."
fi

# ---------------------------------------------------------------------------
# Step 4 — Update pref_jre.cfg and inst_jre.cfg
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] Updating install4j JRE config files..."

INSTALL4J_DIR="${ATOM_HOME}/.install4j"
if [ ! -d "$INSTALL4J_DIR" ]; then
    echo "ERROR: .install4j directory not found at: $INSTALL4J_DIR"
    exit 1
fi

echo "$CORRETTO_HOME" > "${INSTALL4J_DIR}/pref_jre.cfg"
echo "$CORRETTO_HOME" > "${INSTALL4J_DIR}/inst_jre.cfg"
echo "         pref_jre.cfg -> $CORRETTO_HOME"
echo "         inst_jre.cfg -> $CORRETTO_HOME"

# ---------------------------------------------------------------------------
# Step 5 — Update libjvm.so symlink (required for collectd / JMX)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 5] Updating /usr/lib64/libjvm.so symlink..."

LIBJVM_SYMLINK="/usr/lib64/libjvm.so"
LIBJVM_LOCATION=$(find "$CORRETTO_HOME" -name "libjvm.so" 2>/dev/null | head -1)

if [ -z "$LIBJVM_LOCATION" ]; then
    echo "WARNING: libjvm.so not found under $CORRETTO_HOME. Skipping symlink update."
else
    if [ -L "$LIBJVM_SYMLINK" ] || [ -f "$LIBJVM_SYMLINK" ]; then
        rm -f "$LIBJVM_SYMLINK"
    fi
    ln -s "$LIBJVM_LOCATION" "$LIBJVM_SYMLINK"
    echo "         $LIBJVM_SYMLINK -> $LIBJVM_LOCATION"
fi

# ---------------------------------------------------------------------------
# Step 6 — Set JAVA_HOME system-wide (optional convenience)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 6] Setting JAVA_HOME in /etc/environment..."
if grep -q "^JAVA_HOME=" /etc/environment 2>/dev/null; then
    sed -i "s|^JAVA_HOME=.*|JAVA_HOME=${CORRETTO_HOME}|" /etc/environment
else
    echo "JAVA_HOME=${CORRETTO_HOME}" >> /etc/environment
fi
echo "         JAVA_HOME=${CORRETTO_HOME}"

# ---------------------------------------------------------------------------
# Step 7 — Start the Boomi runtime
# ---------------------------------------------------------------------------
echo ""
echo "[Step 7] Starting Boomi runtime..."
sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" start
echo "         Waiting for runtime to come online (max 180s)..."
START_TIMEOUT=180
START_ELAPSED=0
until sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" status 2>/dev/null | grep -qi "running"; do
    if [ $START_ELAPSED -ge $START_TIMEOUT ]; then
        echo "WARNING: Runtime did not report 'running' within ${START_TIMEOUT}s."
        echo "         Check logs at: ${ATOM_HOME}/bin/atom.log"
        break
    fi
    sleep 5
    START_ELAPSED=$((START_ELAPSED + 5))
    echo "         Waiting... (${START_ELAPSED}s)"
done
if sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" status 2>/dev/null | grep -qi "running"; then
    echo "         Runtime is online after ${START_ELAPSED}s."
fi

# ---------------------------------------------------------------------------
# Step 8 — Verify
# ---------------------------------------------------------------------------
echo ""
echo "[Step 8] Verifying..."

STATUS=$(sudo -u $BOOMI_USER "${ATOM_HOME}/bin/atom" status 2>&1)
echo "         Atom status: $STATUS"

JAVA_PROC=$(ps aux | grep java | grep -v grep | grep "$ATOM_HOME" || true)
if [ -n "$JAVA_PROC" ]; then
    echo "         Java process found."
    # Print the java binary path from the running process
    PID=$(ps aux | grep java | grep -v grep | grep "$ATOM_HOME" | awk '{print $2}' | head -1)
    if [ -n "$PID" ]; then
        JAVA_BINARY=$(readlink -f /proc/$PID/exe 2>/dev/null || echo "unknown")
        echo "         Running JVM binary : $JAVA_BINARY"
    fi
else
    echo "WARNING: No Java process found for $ATOM_HOME. The runtime may still be starting."
    echo "         Check logs at: $ATOM_HOME/bin/atom.log"
fi

echo ""
echo "=================================================================="
echo " Migration complete."
echo " Corretto path : $CORRETTO_HOME"
echo " Confirm in Boomi UI:"
echo "   Manage > Runtime Management > $ATOM_NAME"
echo "   > Startup Properties > Java Version"
echo "=================================================================="
