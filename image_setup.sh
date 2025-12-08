#!/bin/bash
set -x

# Start with Cloudlab Ubuntu 24.04 image

# Use particular docker and kubernetes versions. When I've tried to upgrade, I've seen slowdowns in 
# pod creation.
DOCKER_VERSION_STRING=5:27.3.1-1~ubuntu.24.04~noble
KUBERNETES_VERSION_STRING=1.34

# Unlike home directories, this directory will be included in the image
USER_GROUP=eebpf
INSTALL_DIR=/home/eebpf

# General updates
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

# Pip is useful
sudo apt install -y python3-pip
python3 -m pip install --upgrade pip

# Install docker (https://docs.docker.com/engine/install/ubuntu/)
sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    apt-transport-https \
    lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce=$DOCKER_VERSION_STRING docker-ce-cli=$DOCKER_VERSION_STRING containerd.io docker-compose-plugin

# Set to use cgroupdriver
echo -e '{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker || (echo "ERROR: Docker installation failed, exiting." && exit -1)
sudo docker run hello-world | grep "Hello from Docker!" || (echo "ERROR: Docker installation failed, exiting." && exit -1)


curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION_STRING}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION_STRING}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# Set to use private IP
sudo sed -i.bak "s/KUBELET_CONFIG_ARGS=--config=\/var\/lib\/kubelet\/config\.yaml/KUBELET_CONFIG_ARGS=--config=\/var\/lib\/kubelet\/config\.yaml --node-ip=REPLACE_ME_WITH_IP/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# HELM
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# GO
sudo wget https://go.dev/dl/go1.25.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.25.5.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile

# Create $USER_GROUP group so $INSTALL_DIR can be accessible to everyone
sudo groupadd $USER_GROUP
sudo mkdir $INSTALL_DIR
sudo chgrp -R $USER_GROUP $INSTALL_DIR
sudo chmod -R o+rw $INSTALL_DIR