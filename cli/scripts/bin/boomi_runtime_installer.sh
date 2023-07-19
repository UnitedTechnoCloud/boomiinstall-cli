#!/bin/bash
#set -x
if [ -n ${platform} ] ; then
    if [[ -f /etc/boomi_runtime_installer ]]; then 
        echo "boomi_runtime_installer already run so will not be run again!"
        exit 0; 
    fi
fi

echo "begin boomi install..."
USR=boomi
GRP=boomi
whoami
echo "Cloud Platform : ${platform}"
echo "Atom Name : ${atomName}"
echo "Atom Type : ${atomType}"
echo "Boomi Environment : ${boomiEnv}"
echo "purge Days : ${purgeHistoryDays}"
echo "max Memory : ${maxMem}"
echo "efsMount : ${EfsMount}"
echo "githubToken : ${githubToken}"

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

#mkdir -p  /home/$USR/boomi/boomicicd
#cd /home/$USR/boomi/boomicicd
#echo "git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli..."
#git clone https://${githubToken}@github.com/UnitedTechnoCloud/boomicicd-cli
#git clone https://github.com/UnitedTechnoCloud/boomiinstall-cli
cd /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/
set +e

# download Boomi installers
echo "download boomi installers..."
curl -fsSL https://platform.boomi.com/atom/atom_install64.sh -o atom_install64.sh && chmod +x "atom_install64.sh"
curl -fsSL https://platform.boomi.com/atom/molecule_install64.sh -o molecule_install64.sh && chmod +x "molecule_install64.sh"
curl -fsSL https://platform.boomi.com/atom/cloud_install64.sh -o cloud_install64.sh && chmod +x "cloud_install64.sh"
cp scripts/home/* /home/$USR

# Create the .profile
cd /home/$USR
echo "export JAVA_HOME='/usr/bin/java'" > .profile
echo "export JDK_HOME='/usr/bin/java'" >> .profile
echo "export JOURNAL_STREAM='9:132367794'" >> .profile
echo "export LANG='C.utf8'" >> .profile
echo "export LOGNAME='root'" >> .profile
echo "export SHLVL='2'" >> .profile           
echo "export color_prompt=true" >> .profile            
chmod u+x /home/$USR/.profile
echo "if [ -f /home/$USR/.profile ]; then" >> /home/$USR/.bashrc
echo "	. /home/$USR/.profile" >> /home/$USR/.bashrc
echo "fi" >> /home/$USR/.bashrc
cp /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/scripts/home/.profile .
if [ "${platform}" = "aws" ]; then
    EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
    EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
    echo "export AWS_DEFAULT_REGION=$EC2_REGION" >> .profile	
    source /home/$USR/.profile
fi
            
# set up local directories for install
mkdir -p /mnt/boomi
mkdir -p /usr/local/boomi/work
mkdir -p /usr/local/boomi/tmp
mkdir -p /usr/local/bin
chown -R $USR:$GRP /mnt/boomi/
chown -R $USR:$GRP /home/$USR/
chown -R $USR:$GRP /usr/local/boomi/
chown -R $USR:$GRP /usr/local/bin/
whoami

# install boomi
sudo -u $USR bash << EOF
echo "install boomi runtime as $USR"
if [ "${platform}" = "aws" ]; then
    echo "Hello, I am running as $USR"
    source /home/$USR/.profile
    # Your script commands go here
    echo "Created File System is ${EfsMount}"
    export efsMount=${EfsMount}
    export atomName=${atomName}
    export env=${boomiEnv}
    echo "environment is ${boomiEnv}"
    echo "purge Days is ${purgeHistoryDays}"
    echo "max Memory is ${maxMem}"
    export atomType=${atomType}
    export defaultRegion=${defaultRegion}
    export defaultAWSRegion=${region} 
    #export userName=${userName}
    #export apiToken=${apiToken}
    export classification=${classification}
    export region=${region}
    export DataDogAPIKey=${DataDogAPIKey}
    cd /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/scripts
    source bin/efsMount.sh efsMount=${EfsMount} defaultAWSRegion=${region}
    #export authToken="BOOMI_TOKEN.$userName:$apiToken"
    export authToken=${authToken}
	env
    source bin/init.sh atomType=${atomType} atomName=${atomName} env=${boomiEnv} classification=${classification} accountId=${accountId}	purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem} defaultRegion=${defaultRegion}
else
    # GCP/Azure platforms
    cd /home/$USR/boomi/boomicicd/boomiinstall-cli/cli/scripts
    source bin/exports.sh
    source bin/efsMount.sh efsMount=${efsMount}
    echo "run init.sh..."
    sudo su - $USR -c "cd ~/boomi/boomicicd/boomiinstall-cli/cli/scripts;export authToken=${boomiAtmosphereToken};. bin/init.sh atomType=${atomType} atomName=${atomName} env=${boomiEnv} classification=${boomiClassification} accountId=${boomiAccountId} purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem}"
fi
EOF

echo "boomi install complete..."

if [ -n ${platform} ] ; then
  touch /etc/boomi_runtime_installer
  echo "boomi_runtime_installer flag created"
fi