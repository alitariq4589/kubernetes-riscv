#!/bin/bash

# ============================================
# Control Plane Setup for x86 with Custom Flannel
# ============================================

# Configuration - CHANGE THE VERSIONS AS NEEDED FROM THE RELEASES
DOCKERHUB_USER="cloudv10x"  # Your DockerHub username
PAUSE_VERSION="3.10"
FLANNEL_VERSION="0.28.0"

set -e  # Exit on any error

echo "============================================"
echo "Kubernetes Control Plane Setup (x86)"
echo "============================================"
echo ""
echo "Using custom images:"
echo "  Pause: ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo "  Flannel: ${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"
echo ""

# --- CLEANUP SECTION ---
echo "Step 1: Cleaning up existing Kubernetes installation..."

# Stop kubelet service if running
sudo systemctl stop kubelet 2>/dev/null || true

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

# --- SETUP KUBELET SERVICE (for manual binary installations) ---
echo "Step 3: Setting up kubelet systemd service..."

# Check if kubelet is already installed via package manager
if dpkg -l | grep -q kubelet; then
    echo "kubelet package detected - skipping manual service setup"
else
    echo "Setting up kubelet service for manually installed binaries..."
    
    # Create kubelet service file
    sudo mkdir -p /etc/systemd/system/kubelet.service.d

    cat <<'KUBELET_SERVICE' | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
KUBELET_SERVICE

    # Create kubelet drop-in configuration
    cat <<'KUBELET_DROPIN' | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
KUBELET_DROPIN

    # Create kubelet defaults file
    sudo mkdir -p /etc/default
    cat <<'KUBELET_DEFAULTS' | sudo tee /etc/default/kubelet
# Additional kubelet arguments
KUBELET_EXTRA_ARGS=
KUBELET_DEFAULTS

    # Create required directories
    sudo mkdir -p /var/lib/kubelet
    sudo mkdir -p /etc/kubernetes/manifests
    sudo mkdir -p /etc/kubernetes/pki

    # Enable kubelet service
    sudo systemctl daemon-reload
    sudo systemctl enable kubelet
    
    echo "✓ kubelet service configured"
fi

echo ""

# --- INSTALL KUBERNETES (if using package manager) ---
echo "Step 4: Checking Kubernetes installation..."
if command -v kubeadm &> /dev/null && command -v kubelet &> /dev/null && command -v kubectl &> /dev/null; then
    echo "Kubernetes binaries found - skipping installation"
else
    echo "Installing Kubernetes from repository..."
    # Add Kubernetes repository
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl

    echo "✓ Kubernetes installed"
fi

echo ""

# --- INITIALIZE CONTROL PLANE ---
echo "Step 5: Initializing Kubernetes control plane..."

sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Configure kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "✓ Control plane initialized"
echo ""

# --- INSTALL HELM ---
echo "Step 6: Installing Helm..."

if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "✓ Helm installed"
echo ""

# --- INSTALL FLANNEL WITH CUSTOM IMAGES ---
echo "Step 7: Installing Flannel with custom images..."

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
echo "Step 8: Waiting for Flannel to be ready..."
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
echo "All Pods:"
kubectl get pods --all-namespaces
echo ""
echo "============================================"
echo "To join worker nodes:"
echo "============================================"
echo ""
echo "1. Get the join command:"
echo ""
sudo kubeadm token create --print-join-command
echo ""
echo "2. Run the worker-node-setup.sh script on each worker node"
echo "   with the join command above"
echo ""
echo "============================================"
echo ""
echo "Useful Commands:"
echo "  kubectl get nodes                  # Check node status"
echo "  kubectl get pods -A                # Check all pods"
echo "  sudo systemctl status kubelet      # Check kubelet service"
echo "  sudo journalctl -u kubelet -f      # View kubelet logs"
echo "============================================"