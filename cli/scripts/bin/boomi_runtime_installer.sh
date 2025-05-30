#!/bin/bash
#set -x
if [ -n "$platform" ] ; then
    if [[ -f /etc/boomi_runtime_installer ]]; then 
        echo "boomi_runtime_installer already run so will not be run again!"
        exit 0; 
    fi
fi

echo "begin boomi install with new efs script main branch..."
USR=boomi
GRP=boomi
whoami
echo "Cloud Platform : ${platform}"
echo "Atom Name : ${atomName}"
echo "Atom Type : ${atomType}"
echo "Boomi Environment : ${boomiEnv}"
echo "purge Days : ${purgeHistoryDays}"
echo "max Memory : ${maxMem}"
echo "efsMount : ${efsMount}"
echo "installDir : ${installDir}"
echo "workDir : ${workDir}"
echo "tmpDir : ${tmpDir}"
#  create boomi user
sudo groupadd -g 5151 -r $GRP
sudo useradd -u 5151 -g $GRP -r -m -s /bin/bash $USR
sudo usermod -aG sudo boomi
echo "boomi ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
sudo apt-get -y update
echo "install python..."
sudo apt-get install -y zip -y
sudo apt-get install python3-pip -y
python3 --version
sudo apt-get install -y ca-certificates curl gnupg  lsb-release -y

# set ulimits
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608
sudo sysctl -w net.core.rmem_default=65536
sudo sysctl -w net.core.wmem_default=65536
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nofile" "8192" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nofile" "8192" | sudo tee -a /etc/security/limits.conf

# install java
echo "install java..."
sudo apt-get update && sudo apt-get install -y java-common -y
curl -fssL https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.deb -o amazon-corretto-11-x64-linux-jdk.deb
sudo dpkg --install amazon-corretto-11-x64-linux-jdk.deb
cd /usr/lib/jvm/
sudo ln -sf java-11-amazon-corretto/ jre
sudo apt-get -y install git binutils -y
sudo apt-get -y install nfs-common

if [ "${platform}" = "aws" ]; then
    sudo apt-get install -y awscli
    sudo apt-get -y install git binutils
    cd /tmp
    git clone https://github.com/aws/efs-utils
    cd /tmp/efs-utils
    ./build-deb.sh
    sudo apt-get -y install ./build/amazon-efs-utils*deb
else
    echo "awscli install not required!"
fi

set -e
## download boomicicd CLI 
sudo apt-get install -y jq -y
sudo apt-get install -y libxml2-utils -y
# sudo apt-get install tshark -y

mkdir -p  /home/$USR/boomi/boomicicd
cd /home/$USR/boomi/boomicicd
echo "git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli..."
git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli
cd /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/
chmod +x scripts/bin/*.*
chmod +x scripts/home/*.*
set +e

# download Boomi installers
echo "download boomi installers..."
curl -fsSL https://platform.boomi.com/atom/atom_install64.sh -o atom_install64.sh && chmod +x "atom_install64.sh"
curl -fsSL https://platform.boomi.com/atom/molecule_install64.sh -o molecule_install64.sh && chmod +x "molecule_install64.sh"
curl -fsSL https://platform.boomi.com/atom/cloud_install64.sh -o cloud_install64.sh && chmod +x "cloud_install64.sh"
curl -fsSL https://platform.boomi.com/atom/gateway_install64.sh -o gateway_install64.sh && chmod +x "gateway_install64.sh"
cp scripts/home/* /home/$USR

# Create the .profile
cd /home/$USR
cp /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/scripts/home/.profile .
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
cd /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/scripts
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
. bin/init.sh atomType="${atomType}" atomName="${atomName}" env="${boomiEnv}" classification=${boomiClassification} accountId=${boomiAccountId} purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem} client=${client} group=${group} installDir=${installDir} workDir=${workDir} tmpDir=${tmpDir}
EOF

echo "boomi install complete..."

if [ -n "$platform" ] ; then
  touch /etc/boomi_runtime_installer
  echo "boomi_runtime_installer flag created"
fi
