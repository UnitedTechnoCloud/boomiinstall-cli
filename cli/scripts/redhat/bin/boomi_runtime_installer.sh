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
USR=boomi
GRP=boomi
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

# Detect package manager: prefer dnf (RHEL 8+), fall back to yum (RHEL 7/CentOS 7)
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
else
    PKG_MGR="yum"
fi
echo "Using package manager: ${PKG_MGR}"

#  create boomi user
sudo groupadd -g 5151 -r $GRP
sudo useradd -u 5151 -g $GRP -r -m -s /bin/bash $USR
# On RedHat, the privileged group is 'wheel' (not 'sudo')
sudo usermod -aG wheel boomi
echo "boomi ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
sudo ${PKG_MGR} -y update
echo "install python..."
sudo ${PKG_MGR} install -y zip
sudo ${PKG_MGR} install -y python3-pip
python3 --version
sudo ${PKG_MGR} install -y ca-certificates curl gnupg2

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
sudo ${PKG_MGR} install -y git binutils nfs-utils

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

mkdir -p  /home/$USR/boomi/boomicicd
cd /home/$USR/boomi/boomicicd

# Check if BOOMI_CLI_PATH is set and exists (from bootstrap script)
if [ -n "$BOOMI_CLI_PATH" ] && [ -d "$BOOMI_CLI_PATH" ]; then
    echo "Using existing boomiinstall-cli from bootstrap at: $BOOMI_CLI_PATH"
    CLI_PATH="$BOOMI_CLI_PATH"
elif [ -d "boomiinstall-cli" ]; then
    echo "boomiinstall-cli already exists in current directory, using it..."
    CLI_PATH="/home/$USR/boomi/boomicicd/boomiinstall-cli"
else
    echo "git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli..."
    git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli
    CLI_PATH="/home/$USR/boomi/boomicicd/boomiinstall-cli"
fi

cd $CLI_PATH/cli/
chmod +x scripts/redhat/bin/*.*
chmod +x scripts/redhat/home/*.*
set +e

# download Boomi installers
echo "download boomi installers..."
curl -fsSL https://platform.boomi.com/atom/atom_install64.sh -o atom_install64.sh && chmod +x "atom_install64.sh"
curl -fsSL https://platform.boomi.com/atom/molecule_install64.sh -o molecule_install64.sh && chmod +x "molecule_install64.sh"
curl -fsSL https://platform.boomi.com/atom/cloud_install64.sh -o cloud_install64.sh && chmod +x "cloud_install64.sh"
curl -fsSL https://platform.boomi.com/atom/gateway_install64.sh -o gateway_install64.sh && chmod +x "gateway_install64.sh"
cp scripts/redhat/home/* /home/$USR

# Create the .profile
cd /home/$USR
cp $CLI_PATH/cli/scripts/redhat/home/.profile .
echo "export platform=${platform}" >> .profile
chmod u+x /home/$USR/.profile
echo "if [ -f /home/$USR/.profile ]; then" >> /home/$USR/.bashrc
echo "	. /home/$USR/.profile" >> /home/$USR/.bashrc
echo "fi" >> /home/$USR/.bashrc
if [ "${platform}" = "aws" ]; then
    EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
    EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
    echo "export AWS_DEFAULT_REGION=$EC2_REGION" >> .profile	
    source /home/$USR/.profile
fi

if [ -n "$installDir" ] ; then
      mkdir -p /opt/boomi/local
      chown -R $USR:$GRP /opt/boomi/local 
fi

# set up local directories for install
mkdir -p /mnt/boomi
mkdir -p /usr/local/boomi/work
mkdir -p /usr/local/boomi/tmp
mkdir -p /usr/local/bin
mkdir -p /data/tmp
mkdir -p /data/work
chown -R $USR:$GRP /mnt/boomi/
chown -R $USR:$GRP /home/$USR/
chown -R $USR:$GRP /usr/local/boomi/
chown -R $USR:$GRP /usr/local/bin/
chown -R $USR:$GRP /data
whoami

# install boomi
sudo -u $USR bash << EOF
echo "install boomi runtime as $USR"
cd $CLI_PATH/cli/scripts/redhat
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
. bin/init.sh atomType="${atomType}" atomName="${atomName}" env="${boomiEnv}" classification=${boomiClassification} accountId=${boomiAccountId} cloudId=${cloudId} purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem} client=${client} group=${group} installDir=${installDir} workDir=${workDir} tmpDir=${tmpDir}
EOF

echo "boomi install complete..."

if [ -n "$platform" ] ; then
  touch /etc/boomi_runtime_installer
  echo "boomi_runtime_installer flag created"
fi
