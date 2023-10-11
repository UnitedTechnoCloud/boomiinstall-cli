#!/bin/bash
# mount efs
source bin/common.sh
ARGUMENTS=(efsMount)
OPT_ARGUMENTS=(mountPoint serviceUserName groupName defaultAWSRegion platform)
authToken="BOOMI_TOKEN."
inputs "$@"

echo "Default Region is: ${defaultRegion}"
if [ "$?" -gt "0" ]
then
       return 255;
fi


if [[ -z "${mountPoint}" ]]; then
	mountPoint="/mnt/boomi";
fi

if [[ -z "${serviceUserName}" ]]; then
	serviceUserName="boomi";
fi

if [[ -z "${groupName}" ]]; then
	groupName="boomi";
fi

if [[ -z "${defaultAWSRegion}" ]]; then
	defaultAWSRegion="us-east-2";
fi


## update fstab
if [ "${platform}" = "aws" ]; then
        export EC2_AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
        export EC2_REGION="`echo \"$EC2_AVAIL_ZONE\" | sed 's/[a-z]$//'`"	
	sudo mount -t efs -o tls ${efsMount}.efs.${EC2_REGION}.amazonaws.com:/ "${mountPoint}"
	echo "${efsMount}.efs.${EC2_REGION}.amazonaws.com:/ $mountPoint nfs4 defaults,_netdev 0 0" | sudo tee -a /etc/fstab
elif [ "${platform}" = "azure" ]; then
	echo "${efsMount} $mountPoint nfs vers=4,minorversion=1,sec=sys 0 0" | sudo tee -a /etc/fstab
else
	# GCP/Azure platforms
	echo "mounting ${efsMount}..."
	echo "${efsMount} $mountPoint nfs4 defaults,_netdev 0 0" | sudo tee -a /etc/fstab
fi
sudo mount -a
sudo chown -R $serviceUserName:$groupName "${mountPoint}"
