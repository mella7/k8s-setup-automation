#!/bin/bash

set -e  # Exit immediately on failure

echo "Starting Kubernetes installation..."

# Step 1: Set SELinux to permissive
echo "Configuring SELinux..."
if sudo setenforce 0; then
    echo "SELinux set to permissive."
else
    echo "SELinux may already be in permissive mode. Proceeding..."
fi
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config || true

# Step 2: Update and install prerequisites
echo "Updating system and installing prerequisites..."
sudo yum update -y
sudo yum install -y yum-utils device-mapper-persistent-data lvm2 curl jq

# Step 3: Disable swap
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Step 4: Enable kernel modules
echo "Enabling kernel modules..."
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Step 5: Configure sysctl
echo "Configuring sysctl settings..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# Step 6: Install containerd
if ! command -v containerd &>/dev/null; then
    echo "Installing containerd..."
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y containerd.io
else
    echo "containerd is already installed."
fi

# Step 7: Configure containerd
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Step 8: Configure crictl
echo "Configuring crictl..."
sudo mkdir -p /etc
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# Step 9: Add Kubernetes repository
echo "Adding Kubernetes repository..."
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
EOF

sudo yum update -y

# Step 10: Install Kubernetes components
echo "Installing kubelet, kubeadm, and kubectl..."
sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable --now kubelet

# Step 11: Pull required images
PAUSE_IMAGE="registry.k8s.io/pause:3.9"
echo "Pulling the pause image: $PAUSE_IMAGE..."
sudo crictl pull $PAUSE_IMAGE

# Step 12: Initialize Kubernetes cluster
read -p "Enter the API server advertise address (e.g., 10.2.0.4): " API_SERVER_ADDRESS
read -p "Enter the Pod Network CIDR (e.g., 192.168.0.0/16): " POD_NETWORK_CIDR

echo "Initializing Kubernetes cluster..."
sudo kubeadm init --apiserver-advertise-address "$API_SERVER_ADDRESS" --pod-network-cidr="$POD_NETWORK_CIDR"

# Step 13: Configure kubectl for the current user
echo "Configuring kubectl for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u):$(id -g)" $HOME/.kube/config

# Step 14: Deploy Calico as the pod network add-on
echo "Deploying Calico as the pod network add-on..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/calico.yaml

# Step 15: Allow workloads on control plane
echo "Allowing workloads on the control plane..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Step 16: Verify the Installation
echo "Verifying the Kubernetes cluster setup..."
kubectl get nodes
kubectl get pods -A

echo "Kubernetes installation completed successfully!"
