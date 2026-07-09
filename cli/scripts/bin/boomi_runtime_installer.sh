#!/bin/bash
set -e

# Guard: prevent re-runs on the same host
if [ -f /etc/boomi_runtime_installer ]; then
    echo "boomi_runtime_installer already run, exiting."
    exit 0
fi

echo "Begin Boomi Install (RHEL / Kerberos)..."

# --- Service account (Kerberos principal, managed by AD/SSSD — no local useradd) ---
export USR='srvcboomipd.us@usplexus.com'
export USR1='srvcboomipd.us@USPLEXUS.COM'
export GRP=${GRP:-513}
export HOME_DIR="/home/srvcboomipd.us"

# --- Runtime parameters sourced from user-data / environment ---
export mountPoint="${mountPoint:-/mnt/boomi}"
export platform="${platform:-gcp}"
export atomType="${atomType:-MOLECULE}"
export client="${client}"
export group="${group}"
export env="${boomiEnv:-${env}}"
export efsMount="${efsMount}"
export nfsVersion="${nfsVersion:-4.1}"
# Normalise atom name: hyphens → underscores (Boomi convention)
export atomName="$(echo "${atomName}" | sed -e 's/-/_/g')"

echo "Cloud Platform : ${platform}"
echo "Atom Name      : ${atomName}"
echo "Atom Type      : ${atomType}"
echo "Environment    : ${env}"
echo "Mount Point    : ${mountPoint}"
echo "EFS/NFS Mount  : ${efsMount}"

# --- Wait for RHSM registration (runs concurrently with first boot) ---
echo "Waiting for RHSM entitlement registration..."
for i in $(seq 1 30); do
  if subscription-manager identity &>/dev/null; then
    echo "RHSM registered (attempt $i)"
    break
  fi
  echo "  RHSM not ready yet, waiting 10s (attempt $i/30)..."
  sleep 10
done

# --- System packages ---
sudo dnf clean all
sudo dnf update -y
echo "install python..."
sudo dnf install -y zip
sudo dnf install -y python3-pip
python3 --version
sudo dnf install -y ca-certificates curl gnupg2

# --- ulimits ---
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608
sudo sysctl -w net.core.rmem_default=65536
sudo sysctl -w net.core.wmem_default=65536
printf "%s\t\t%s\t\t%s\t\t%s\n" "$USR" "soft" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" "$USR" "hard" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" "$USR" "soft" "nofile" "8192" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" "$USR" "hard" "nofile" "8192" | sudo tee -a /etc/security/limits.conf

# --- Java: Amazon Corretto 11 via RPM repository (no amazon-linux-extras required) ---
echo "install java (Amazon Corretto 11)..."
sudo rpm --import https://yum.corretto.aws/corretto.key
sudo curl -fsSL -o /etc/yum.repos.d/corretto.repo https://yum.corretto.aws/corretto.repo
sudo dnf install -y java-11-amazon-corretto-devel
cd /usr/lib/jvm/ || exit 1
sudo ln -sf java-11-amazon-corretto/ jre
sudo dnf install -y git binutils
sudo dnf install -y nfs-utils jq libxml2

# --- Ensure home directory exists (SSSD may not have created it yet) ---
mkdir -p "${HOME_DIR}"

# --- Write home scripts ---
echo "Writing home scripts to ${HOME_DIR}..."

# restart.sh — variables evaluated at runtime, so use single-quoted heredoc
cat > "${HOME_DIR}/restart.sh" <<'EOL'
#!/bin/bash
source /home/srvcboomipd.us/.profile
restart_log="restart_${ATOM_LOCALHOSTID}.log"
date >> "${restart_log}" 2>&1
echo "Using systemd for restart. Check journalctl for logs." >> "${restart_log}" 2>&1
sudo systemctl restart atom
EOL
chown "$USR:$GRP" "${HOME_DIR}/restart.sh"
chmod 755 "${HOME_DIR}/restart.sh"
echo "File ${HOME_DIR}/restart.sh has been created."

# start-atom.sh
cat > "${HOME_DIR}/start-atom.sh" <<'EOL'
#!/bin/bash
source /home/srvcboomipd.us/.profile
atom start
atom status
exit 0
EOL
chown "$USR:$GRP" "${HOME_DIR}/start-atom.sh"
chmod 755 "${HOME_DIR}/start-atom.sh"
echo "File ${HOME_DIR}/start-atom.sh has been created."

# stop-atom.sh
cat > "${HOME_DIR}/stop-atom.sh" <<'EOL'
#!/bin/bash
source /home/srvcboomipd.us/.profile
atom stop
atom status
exit 0
EOL
chown "$USR:$GRP" "${HOME_DIR}/stop-atom.sh"
chmod 755 "${HOME_DIR}/stop-atom.sh"
echo "File ${HOME_DIR}/stop-atom.sh has been created."

# .profile — variables ARE expanded here (platform, client, group, env, atomName)
cat > "${HOME_DIR}/.profile" <<EOL
export JAVA_HOME='/usr/bin/java'
export JDK_HOME='/usr/bin/java'
export platform="${platform}"
export client=${client}
export group=${group}
export environment=${env}
export BOOMI_CONTAINERNAME="${atomName}"
EOL
chown "$USR:$GRP" "${HOME_DIR}/.profile"
chmod 644 "${HOME_DIR}/.profile"
echo ". ${HOME_DIR}/.profile" >> "${HOME_DIR}/.bashrc"
echo "File ${HOME_DIR}/.profile has been created."

# --- Local directories ---
mkdir -p /usr/local/boomi/work
mkdir -p /usr/local/boomi/tmp
mkdir -p /usr/local/bin
mkdir -p /opt/boomi/local

# --- Kerberos: obtain ticket BEFORE accessing the NFS share ---
# Requires /etc/nfs.keytab pre-provisioned for srvcboomipd.us@USPLEXUS.COM
echo "Obtaining Kerberos ticket for ${USR} ..."
sudo -u 'srvcboomipd.us@usplexus.com' kinit -kt /etc/nfs.keytab 'srvcboomipd.us@USPLEXUS.COM'
sudo -u "$USR" klist

# --- Determine ATOM_HOME ---
dir_prefix="Molecule"
if [ "$atomType" = "GATEWAY" ]; then dir_prefix="Gateway"; fi
export ATOM_HOME="${mountPoint}/${dir_prefix}_${atomName}"
echo "ATOM_HOME: ${ATOM_HOME}"
echo "export ATOM_HOME='${ATOM_HOME}'" >> "${HOME_DIR}/.profile"

# --- Discover next available node ID ---
# Scans the molecule's views directory to find an unclaimed molecule_N slot
i=0
while [ $i -lt 10 ]; do
    viewfile_count=$(sudo -u 'srvcboomipd.us@usplexus.com' bash -c \
        "ls ${ATOM_HOME}/bin/views/*molecule_${i}* 2>/dev/null" | wc -l)
    if [ "$viewfile_count" -eq 0 ]; then
        ATOM_LOCALHOSTID=molecule_$i
        break
    else
        i=$((i + 1))
    fi
done
echo "ATOM_LOCALHOSTID: ${ATOM_LOCALHOSTID}"
echo "export ATOM_LOCALHOSTID=${ATOM_LOCALHOSTID}" >> "${HOME_DIR}/.profile"
echo "export pod_name=${ATOM_LOCALHOSTID}" >> "${HOME_DIR}/.profile"

# --- Create systemd service unit ---
echo "create atom.service ..."
cat > /etc/systemd/system/atom.service <<EOF
[Unit]
Description=Boomi ${atomName}
After=network.target
RequiresMountsFor="${mountPoint}"

[Service]
User=${USR}
WorkingDirectory=${HOME_DIR}
PassEnvironment=JAVA_HOME
ExecStart=/bin/bash ${HOME_DIR}/start-atom.sh
ExecStop=/bin/bash ${HOME_DIR}/stop-atom.sh
Type=forking
TimeoutStartSec=600
Restart=always

[Install]
WantedBy=multi-user.target
EOF

ln -sf "${ATOM_HOME}/bin/atom" /usr/local/bin/atom
sudo -u "$USR" cp -f "${HOME_DIR}/restart.sh" "${ATOM_HOME}/bin"

# --- Fix ownership and permissions ---
chown -R "$USR:$GRP" "${HOME_DIR}/"
chmod 755 "${HOME_DIR}/start-atom.sh" "${HOME_DIR}/stop-atom.sh" "${HOME_DIR}/restart.sh"
chown -R "$USR:$GRP" /usr/local/boomi/
chown -R "$USR:$GRP" /usr/local/bin/
chown -R "$USR:$GRP" /opt/boomi/local
# NFS root cannot be chowned; chown contents only (errors suppressed)
sudo -u "$USR" chown -R "$USR:$GRP" /mnt/boomi/* 2>/dev/null || true

# --- Enable and start service ---
echo "setup atom.service ..."
systemctl enable atom
systemctl start atom
systemctl is-active --quiet atom && echo "Service is running..."

touch /etc/boomi_runtime_installer
echo "boomi_runtime_installer flag created"

echo "... Boomi Install Complete."
