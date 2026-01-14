#!/bin/bash

# ============================================
# Control Plane Setup with Custom Flannel
# ============================================

# Configuration - CHANGE THE VERSIONS AS NEEDED FROM THE RELEASES
DOCKERHUB_USER="cloudv10x"  # Your DockerHub username
PAUSE_VERSION="3.10"
FLANNEL_VERSION="0.28.0"

set -e  # Exit on any error

echo "============================================"
echo "Kubernetes Control Plane Setup"
echo "============================================"
echo ""
echo "Using custom images:"
echo "  Pause: ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo "  Flannel: ${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"
echo ""

# --- CLEANUP SECTION ---
echo "Step 1: Cleaning up existing Kubernetes installation..."

# Reset kubeadm
sudo kubeadm reset -f 2>/dev/null || true

# Remove configuration directories
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/etcd/
sudo rm -rf $HOME/.kube/

# Cleanup networking
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo rm -rf /var/lib/cni/
sudo rm -rf /etc/cni/net.d/*

# Remove any Flannel systemd services (from previous attempts)
sudo systemctl stop flanneld 2>/dev/null || true
sudo systemctl disable flanneld 2>/dev/null || true
sudo rm -f /etc/systemd/system/flanneld.service
sudo systemctl daemon-reload

# Flush iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Remove CNI binaries from previous installs
sudo rm -f /opt/cni/bin/*flannel* 2>/dev/null || true
sudo rm -f /usr/local/bin/flanneld 2>/dev/null || true

echo "✓ Cleanup complete"
echo ""

# --- INSTALL DEPENDENCIES ---
echo "Step 2: Installing dependencies..."

# Update system
sudo apt-get update
sudo apt-get upgrade -y

# Install containerd
sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# *** CRITICAL: Configure custom pause image ***
echo "Configuring custom pause image..."
sudo sed -i "s|sandbox_image = .*|sandbox_image = \"${DOCKERHUB_USER}/pause:${PAUSE_VERSION}\"|g" /etc/containerd/config.toml

# Verify pause image configuration
echo "Verifying pause image configuration:"
grep sandbox_image /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

echo "✓ Containerd configured"
echo ""

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo "✓ System configured"
echo ""

# --- INSTALL KUBERNETES ---
echo "Step 3: Installing Kubernetes..."

# Add Kubernetes repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "✓ Kubernetes installed"
echo ""

# --- INITIALIZE CONTROL PLANE ---
echo "Step 4: Initializing Kubernetes control plane..."

sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Configure kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "✓ Control plane initialized"
echo ""

# --- INSTALL HELM ---
echo "Step 5: Installing Helm..."

if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "✓ Helm installed"
echo ""

# --- INSTALL FLANNEL WITH CUSTOM IMAGES ---
echo "Step 6: Installing Flannel with custom images..."

# Add Flannel Helm repo
helm repo add flannel https://flannel-io.github.io/flannel/
helm repo update

# Create namespace
kubectl create namespace kube-flannel
kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged

# Install Flannel with custom image
helm install flannel \
  --namespace kube-flannel \
  --set podCidr="10.244.0.0/16" \
  --set image.repository="${DOCKERHUB_USER}/flannel" \
  --set image.tag="${FLANNEL_VERSION}" \
  flannel/flannel

echo "✓ Flannel installed"
echo ""

# Wait for Flannel to be ready
echo "Step 7: Waiting for Flannel to be ready..."
sleep 20

# Check status
kubectl get pods -n kube-flannel

echo ""
echo "============================================"
echo "✓ Control Plane Setup Complete!"
echo "============================================"
echo ""
echo "Cluster Status:"
kubectl get nodes
echo ""
echo "Flannel Pods:"
kubectl get pods -n kube-flannel
echo ""
echo "============================================"
echo "To join worker nodes:"
echo "============================================"
echo ""
echo "1. Get the join command:"
echo ""
sudo kubeadm token create --print-join-command
echo ""
echo "2. Run the setup-worker.sh script on each worker node"
echo "   with the join command above"
echo ""
echo "============================================"