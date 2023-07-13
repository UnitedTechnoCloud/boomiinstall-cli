#!/bin/bash
#set -x
USR=boomi
GRP=boomi
whoami
echo "Cloud Platform is: ${platform}"
echo "Atom Name is: ${atomName}"
echo "Atom Type is: ${atomType}"

#  create boomi user
sudo groupadd -g 5151 -r $GRP
sudo useradd -u 5151 -g $GRP -r -m -s /bin/bash $USR
sudo usermod -aG sudo boomi
echo "boomi ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
sudo apt-get -y update
sudo apt-get install -y zip
sudo apt-get install python3-pip
python3 --version
sudo apt-get install -y ca-certificates curl gnupg  lsb-release

# set ulimits
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.wmem_max=8388608
sudo sysctl -w net.core.rmem_default=65536
sudo sysctl -w net.core.wmem_default=65536

sudo iptables -A INPUT -p tcp --dport 7800 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 5003 -j ACCEPT
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nproc" "65535" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "soft" "nofile" "8192" | sudo tee -a /etc/security/limits.conf
printf "%s\t\t%s\t\t%s\t\t%s\n" $USR "hard" "nofile" "8192" | sudo tee -a /etc/security/limits.conf

# install java
sudo apt-get update && sudo apt-get install -y java-common
curl -fssL https://corretto.aws/downloads/latest/amazon-corretto-11-x64-linux-jdk.deb -o amazon-corretto-11-x64-linux-jdk.deb
sudo dpkg --install amazon-corretto-11-x64-linux-jdk.deb
cd /usr/lib/jvm/
sudo ln -sf java-11-amazon-corretto/ jre

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

## download boomicicd CLI 
sudo apt-get install -y jq
sudo apt-get install -y libxml2-utils
mkdir -p  /home/$USR/boomi/boomicicd
cd /home/$USR/boomi/boomicicd
#git clone https://${GitUserName}:${GitPAT}/UnitedTechnoCloud/boomicicd-cli.git
git clone https://github.com/TommyJohnWear/boomicicd-cli
cd /home/$USR/boomi/boomicicd/boomicicd-cli/cli/

# download Boomi installers
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

cp /home/$USR/boomi/boomicicd/boomicicd-cli/cli/scripts/home/.profile .
if [ "${platform}" = "aws" ]; then
    EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
    EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"
    echo "aws configure --profile boomi-profile set region $EC2_REGION" >> .profile
    echo "export AWS_DEFAULT_PROFILE=boomi-profile" >> .profile
    echo "export AWS_DEFAULT_REGION=$EC2_REGION" >> .profile 
    source /home/$USR/.profile
else
    echo "awscli install not required!"
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
sudo -u $USR bash << EOF
if [ "${platform}" = "aws" ]; then
    echo "Hello, I am running as $USR"
    source /home/$USR/.profile
    # Your script commands go here
    echo "Created File System is ${EFSMount}"
    export efsMount=${EFSMount}
    export atomName=${atomName}
    export env=${BoomiEnv}
	echo "environment is ${BoomiEnv}"
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
    cd /home/$USR/boomi/boomicicd/boomicicd-cli/cli/scripts
    source bin/efsMount.sh efsMount=${EFSMount} defaultAWSRegion=${region}
	#export authToken="BOOMI_TOKEN.$userName:$apiToken"
	export authToken=${authToken}
    source bin/exports.sh
	env
    source bin/init.sh atomType=${atomType} atomName=${atomName} env=${env} classification=${classification} accountId=${accountId}	purgeHistoryDays=${purgeHistoryDays} maxMem=${maxMem} defaultRegion=${defaultRegion}
else
    echo "awscli install not required!"
fi
EOF