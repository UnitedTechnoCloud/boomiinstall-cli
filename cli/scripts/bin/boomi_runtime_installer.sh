#!/bin/bash
# RedHat/RHEL/CentOS version of boomi_runtime_installer.sh
# Replaces Ubuntu apt-get with dnf/yum, adjusts package names and group membership for RedHat family distros.
#set -x
if [ -n "$platform" ] ; then
    if [[ -f /etc/boomi_runtime_installer ]]; then
        echo "boomi_runtime_installer already run so will not be run again!"
        exit 0;
    fi
fi

echo "begin boomi install (RedHat/RHEL) with new efs script main branch..."
# AD/SSSD service account — no local user creation needed
USR='srvcboomipd.us@usplexus.com'
GRP=513
HOME_DIR="/home/srvcboomipd.us"
whoami
echo "Cloud Platform : ${platform}"
echo "Atom Name : ${atomName}"
echo "Atom Type : ${atomType}"
echo "Account Id : ${boomiAccountId}"
echo "Cloud ID : ${cloudId}"
echo "Auth Token : ${boomiAtmosphereToken}"
echo "Boomi Environment : ${boomiEnv}"
echo "purge Days : ${purgeHistoryDays}"
echo "max Memory : ${maxMem}"
echo "efsMount : ${efsMount}"
echo "installDir : ${installDir}"
echo "workDir : ${workDir}"
echo "tmpDir : ${tmpDir}"

# --- Wait for RHSM registration (runs concurrently with first boot) ---
# Without this, dnf/yum may fail because the entitlement repos are not yet available.
echo "Waiting for RHSM entitlement registration..."
for i in $(seq 1 30); do
  if subscription-manager identity &>/dev/null; then
    echo "RHSM registered (attempt $i)"
    break
  fi
  echo "  RHSM not ready yet, waiting 10s (attempt $i/30)..."
  sleep 10
done

# Detect package manager: prefer dnf (RHEL 8+), fall back to yum (RHEL 7/CentOS 7)
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
else
    PKG_MGR="yum"
fi
echo "Using package manager: ${PKG_MGR}"

# AD/SSSD user already exists via SSSD — grant passwordless sudo for Boomi operations
echo "$USR ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
sudo ${PKG_MGR} -y update
echo "install python..."
sudo ${PKG_MGR} install -y zip
sudo ${PKG_MGR} install -y python3-pip
python3 --version
sudo ${PKG_MGR} install -y ca-certificates curl gnupg2
# Kerberos client tools (kinit/klist) needed for NFS sec=krb5 mounts
sudo ${PKG_MGR} install -y krb5-workstation

# Enable EPEL repository for additional packages (jq, etc.)
echo "enabling EPEL repository..."
if [ "$PKG_MGR" = "dnf" ]; then
    sudo dnf install -y epel-release || \
    sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm || true
else
    sudo yum install -y epel-release || \
    sudo yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm || true
fi
# set ulimits
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608
sudo sysctl -w net.core.rmem_default=65536
sudo sysctl -w net.core.wmem_default=65536
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nofile" "8192" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nofile" "8192" | sudo tee -a /etc/security/limits.conf

# install java (Amazon Corretto 11 - RPM for RedHat)
echo "install java..."
sudo ${PKG_MGR} install -y java-11-amazon-corretto-headless || {
    echo "Corretto not available from default repos, downloading RPM directly..."
    curl -fsSL https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.rpm -o amazon-corretto-11-x64-linux-jdk.rpm
    sudo ${PKG_MGR} localinstall -y amazon-corretto-11-x64-linux-jdk.rpm
}
cd /usr/lib/jvm/
sudo ln -sf java-11-amazon-corretto/ jre || sudo ln -sf $(ls -d java-11-amazon-corretto* | head -1) jre
# On RedHat: nfs-utils replaces ubuntu's nfs-common
sudo ${PKG_MGR} install -y binutils nfs-utils

if [ "${platform}" = "aws" ]; then
    sudo ${PKG_MGR} install -y awscli
    sudo ${PKG_MGR} install -y git binutils
    cd /tmp
    git clone https://github.com/aws/efs-utils
    cd /tmp/efs-utils
    # RedHat uses 'make rpm' to build the RPM package
    make rpm
    sudo ${PKG_MGR} install -y ./build/amazon-efs-utils*rpm
else
    echo "awscli install not required!"
fi

set -e
## download boomicicd CLI
# On RedHat: jq available via EPEL; libxml2 provides xmllint (replaces ubuntu's libxml2-utils)
sudo ${PKG_MGR} install -y jq
sudo ${PKG_MGR} install -y libxml2
# sudo ${PKG_MGR} install -y wireshark

mkdir -p  $HOME_DIR/boomi/boomicicd
cd $HOME_DIR/boomi/boomicicd

# BOOMI_CLI_PATH must point to the repo root (directory containing cli/).
# It is set by boomi-manual-install.sh before sourcing this script.
if [ -n "$BOOMI_CLI_PATH" ] && [ -d "$BOOMI_CLI_PATH/cli" ]; then
    echo "Using boomiinstall-cli from BOOMI_CLI_PATH: $BOOMI_CLI_PATH"
    CLI_PATH="$BOOMI_CLI_PATH"
else
    echo "ERROR: BOOMI_CLI_PATH is not set or does not contain a cli/ subdirectory."
    echo "  BOOMI_CLI_PATH='${BOOMI_CLI_PATH}'"
    echo "  Expected: a path whose cli/ subdirectory exists."
    exit 1
fi

chmod -R 777 $CLI_PATH/cli
cd $CLI_PATH/cli/
chmod +x scripts/bin/*.*
chmod +x scripts/home/*.*
set +e

# download Boomi installers
echo "download boomi installers..."
curl -fsSL https://platform.boomi.com/atom/atom_install64.sh -o scripts/bin/atom_install64.sh && chmod +x "scripts/bin/atom_install64.sh"
curl -fsSL https://platform.boomi.com/atom/molecule_install64.sh -o scripts/bin/molecule_install64.sh && chmod +x "scripts/bin/molecule_install64.sh"
curl -fsSL https://platform.boomi.com/atom/cloud_install64.sh -o scripts/bin/cloud_install64.sh && chmod +x "scripts/bin/cloud_install64.sh"
curl -fsSL https://platform.boomi.com/atom/gateway_install64.sh -o scripts/bin/gateway_install64.sh && chmod +x "scripts/bin/gateway_install64.sh"
cp scripts/home/* $HOME_DIR

# Create the .profile
cd $HOME_DIR
chmod -R 777 $HOME_DIR
cp $CLI_PATH/cli/scripts/home/.profile .
echo "export platform=${platform}" >> .profile
chmod u+x $HOME_DIR/.profile
echo "if [ -f $HOME_DIR/.profile ]; then" >> $HOME_DIR/.bashrc
echo "	. $HOME_DIR/.profile" >> $HOME_DIR/.bashrc
echo "fi" >> $HOME_DIR/.bashrc
if [ "${platform}" = "aws" ]; then
    EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
    EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
    echo "export AWS_DEFAULT_REGION=$EC2_REGION" >> .profile	
    source $HOME_DIR/.profile
fi

mkdir -p /opt/boomi/local
mkdir -p /usr/local/boomi/work
mkdir -p /usr/local/boomi/tmp
mkdir -p /usr/local/bin
mkdir -p /data/tmp
mkdir -p /data/work
# NFS root cannot be chowned (root_squash); chown only the contents
sudo -u "$USR" chown -R "$USR:$GRP" /mnt/boomi/* 2>/dev/null || true
chown -R "$USR:$GRP" $HOME_DIR/
chown -R "$USR:$GRP" /usr/local/boomi/
chown -R "$USR:$GRP" /usr/local/bin/
chown -R "$USR:$GRP" /opt/boomi/local
chown -R "$USR:$GRP" /data
whoami

# --- Kerberos pre-authentication (for NFS mounts secured with sec=krb5) ---
# Activate by setting kerberosEnabled=true, or simply by placing a keytab at kerberosKeytab.
# Defaults target the production service account srvcboomipd.us@usplexus.com.
KERBEROS_USER="${kerberosUser:-srvcboomipd.us@usplexus.com}"
KERBEROS_PRINCIPAL="${kerberosPrincipal:-srvcboomipd.us@USPLEXUS.COM}"
KERBEROS_KEYTAB="${kerberosKeytab:-/etc/nfs.keytab}"

if [ "${kerberosEnabled}" = "true" ] || [ -f "${KERBEROS_KEYTAB}" ]; then
    echo "Kerberos enabled — obtaining ticket for ${KERBEROS_PRINCIPAL} ..."
    sudo -u "${KERBEROS_USER}" kinit -kt "${KERBEROS_KEYTAB}" "${KERBEROS_PRINCIPAL}"
    sudo -u "${KERBEROS_USER}" klist
    echo "Kerberos ticket obtained."
else
    echo "Kerberos not configured (no keytab at ${KERBEROS_KEYTAB}), skipping kinit."
fi

# install boomi
sudo -u $USR bash << EOF
echo "install boomi runtime as $USR"
cd $CLI_PATH/cli/scripts
if [ -n "$efsMount" ] ; then
    echo "setting EFS Mount:${efsMount} ..."
    source bin/efsMount.sh efsMount="${efsMount}" platform=${platform}
fi

#if [ -z "$authToken" ]; then
# authToken="$boomiAtmosphereToken"
#fi
#if [ -z "$authToken" ]; then 
# authToken="BOOMI_TOKEN."
#fi
export authToken=${boomiAtmosphereToken}
export client=${client}
export group=${group}
env
echo "run init.sh..."
. bin/init.sh atomType="${atomType}" atomName="${atomName}" env="${boomiEnv}" classification=${boomiClassification} accountId=${boomiAccountId} cloudId=${cloudId} purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem} client=${client} group=${group} installDir=${installDir} workDir=${workDir} tmpDir=${tmpDir} serviceUserName=${USR%%@*} groupName=${GRP}
EOF

echo "boomi install complete..."

if [ -n "$platform" ] ; then
  touch /etc/boomi_runtime_installer
  echo "boomi_runtime_installer flag created"
fi
