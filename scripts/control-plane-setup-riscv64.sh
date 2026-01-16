#!/bin/bash

# ============================================
# Complete Control Plane Setup with Custom Images
# for RISC-V Kubernetes Cluster
# ============================================

# Configuration - EXACT VERSIONS REQUIRED BY KUBERNETES v1.35.0
DOCKERHUB_USER="cloudv10x"  # Your DockerHub username
K8S_VERSION="1.35.0"        # Kubernetes version
PAUSE_VERSION="3.10"        # Pause container version
FLANNEL_VERSION="0.28.0"    # Flannel version
ETCD_VERSION="3.6.6"        # etcd version (MUST match what kubeadm expects: 3.6.6-0)
COREDNS_VERSION="1.14.0"    # CoreDNS version (default for K8s 1.35)

set -e  # Exit on any error

echo "============================================"
echo "Kubernetes Control Plane Setup for RISC-V"
echo "============================================"
echo ""
echo "Using custom images from DockerHub:"
echo "  User: ${DOCKERHUB_USER}"
echo "  Pause: ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo "  Flannel: ${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"
echo "  kube-apiserver: ${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"
echo "  kube-controller-manager: ${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"
echo "  kube-scheduler: ${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"
echo "  kube-proxy: ${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"
echo "  etcd: ${DOCKERHUB_USER}/etcd:${ETCD_VERSION}"
echo "  coredns: ${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"
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
sudo rm -rf /run/flannel/

# Remove any Flannel systemd services (from previous attempts)
sudo systemctl stop flanneld 2>/dev/null || true
sudo systemctl disable flanneld 2>/dev/null || true
sudo rm -f /etc/systemd/system/flanneld.service
sudo systemctl daemon-reload

# Flush iptables
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Remove CNI binaries from previous installs
sudo rm -f /opt/cni/bin/*flannel* 2>/dev/null || true
sudo rm -f /usr/lib/cni/*flannel* 2>/dev/null || true
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

# *** CRITICAL: Configure CNI binary paths ***
# Ensure containerd knows about both standard locations
sudo sed -i 's|bin_dir = .*|bin_dir = "/opt/cni/bin:/usr/lib/cni"|g' /etc/containerd/config.toml

# Verify pause image configuration
echo "Verifying containerd configuration:"
grep sandbox_image /etc/containerd/config.toml
grep bin_dir /etc/containerd/config.toml

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

# Install crictl
VERSION="v1.28.0"
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-riscv64.tar.gz
sudo tar zxvf crictl-$VERSION-linux-riscv64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-riscv64.tar.gz

# Configure crictl
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# --- SETUP KUBELET SERVICE ---
echo "Step 3: Setting up kubelet systemd service..."

# Create kubelet service file - using /usr/bin for RISC-V manual installs
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
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /usr/lib/cni
sudo mkdir -p /etc/cni/net.d
sudo mkdir -p /run/flannel

# Enable kubelet service
sudo systemctl daemon-reload
sudo systemctl enable kubelet

echo "✓ kubelet service configured"
echo ""

# --- PRE-PULL CUSTOM IMAGES ---
echo "Step 4: Pre-pulling custom Kubernetes images..."

echo "Pulling custom images from ${DOCKERHUB_USER}..."

# Pull all required images
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/pause:${PAUSE_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}
sudo ctr -n k8s.io images pull docker.io/${DOCKERHUB_USER}/flannel-cni-plugin:latest

# Tag images to match what kubeadm expects
echo "Tagging images for kubeadm..."

# Helper to make ctr tagging idempotent
ctr_retag() {
    local src="$1"
    local dst="$2"

    # Remove destination tag if it already exists
    sudo ctr -n k8s.io images rm "$dst" 2>/dev/null || true

    # Re-tag
    sudo ctr -n k8s.io images tag "$src" "$dst"
}

ctr_retag \
  docker.io/${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION} \
  registry.k8s.io/kube-apiserver:v${K8S_VERSION}

ctr_retag \
  docker.io/${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION} \
  registry.k8s.io/kube-controller-manager:v${K8S_VERSION}

ctr_retag \
  docker.io/${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION} \
  registry.k8s.io/kube-scheduler:v${K8S_VERSION}

ctr_retag \
  docker.io/${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION} \
  registry.k8s.io/kube-proxy:v${K8S_VERSION}

ctr_retag \
  docker.io/${DOCKERHUB_USER}/etcd:${ETCD_VERSION}-riscv64 \
  registry.k8s.io/etcd:${ETCD_VERSION}-0

ctr_retag \
  docker.io/${DOCKERHUB_USER}/coredns:${COREDNS_VERSION} \
  registry.k8s.io/coredns/coredns:v${COREDNS_VERSION}

# Also tag pause image
ctr_retag \
  docker.io/${DOCKERHUB_USER}/pause:${PAUSE_VERSION} \
  registry.k8s.io/pause:${PAUSE_VERSION}.1

echo "✓ Custom images pulled and tagged"
echo ""

# --- INSTALL FLANNEL CNI PLUGIN BINARY ---
echo "Step 5: Installing Flannel CNI plugin binary..."

# Extract CNI plugin from the image
TEMP_CONTAINER=$(sudo ctr -n k8s.io run --rm docker.io/${DOCKERHUB_USER}/flannel-cni-plugin:latest temp-extract /bin/sh -c "cat /flannel" > /tmp/flannel-binary)

# Install to both locations for maximum compatibility
sudo install -m 755 /tmp/flannel-binary /opt/cni/bin/flannel
sudo install -m 755 /tmp/flannel-binary /usr/lib/cni/flannel

# Clean up
rm -f /tmp/flannel-binary

echo "✓ Flannel CNI plugin installed to /opt/cni/bin and /usr/lib/cni"
echo ""

# Verify CNI plugin installation
echo "Verifying CNI plugin installation:"
ls -lh /opt/cni/bin/flannel
ls -lh /usr/lib/cni/flannel
echo ""

# --- INITIALIZE CONTROL PLANE ---
echo "Step 6: Initializing Kubernetes control plane..."

sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v${K8S_VERSION}

# Configure kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "✓ Control plane initialized"
echo ""

# --- ALLOW PODS ON CONTROL PLANE (OPTIONAL) ---
echo "Step 7: Configuring control plane node..."

read -p "Do you want to allow pods to run on the control plane node? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Removing control plane taint to allow pod scheduling..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
    echo "✓ Control plane node can now run pods"
else
    echo "Control plane will remain dedicated (no workload pods)"
fi
echo ""

# --- INSTALL HELM ---
echo "Step 8: Installing Helm..."

if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "✓ Helm installed"
echo ""

# --- INSTALL FLANNEL ---
echo "Step 9: Installing Flannel CNI..."

# Add Flannel Helm repo
helm repo add flannel https://flannel-io.github.io/flannel/
helm repo update

# Create namespace
kubectl create namespace kube-flannel
kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged

# Create custom Flannel values file
cat <<EOF > /tmp/flannel-values.yaml
podCidr: "10.244.0.0/16"

# Use custom Flannel image
image:
  repository: ${DOCKERHUB_USER}/flannel
  tag: ${FLANNEL_VERSION}

# Flannel backend configuration
flannel:
  backend: "vxlan"
EOF

# Install Flannel
helm install flannel \
  --namespace kube-flannel \
  --values /tmp/flannel-values.yaml \
  flannel/flannel

echo "✓ Flannel installed"
echo ""

# Wait for Flannel to be ready
echo "Step 10: Waiting for Flannel to initialize..."
echo "This may take up to 2 minutes..."

# Wait for Flannel daemonset to be ready
kubectl wait --for=condition=ready pod \
  -l app=flannel \
  -n kube-flannel \
  --timeout=180s || {
    echo "Warning: Flannel pods took longer than expected to start"
    echo "Checking pod status..."
    kubectl get pods -n kube-flannel
    kubectl describe pods -n kube-flannel
}

# Wait for subnet.env file to be created
timeout=60
elapsed=0
while [ ! -f /run/flannel/subnet.env ] && [ $elapsed -lt $timeout ]; do
    echo "Waiting for Flannel to create subnet.env... ($elapsed/${timeout}s)"
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ -f /run/flannel/subnet.env ]; then
    echo "✓ Flannel subnet.env created successfully"
    cat /run/flannel/subnet.env
else
    echo "Warning: /run/flannel/subnet.env not found after ${timeout}s"
    echo "Flannel may still be initializing. Check with: kubectl logs -n kube-flannel -l app=flannel"
fi

echo ""

# Wait for nodes to be ready
echo "Step 11: Waiting for node to be ready..."
kubectl wait --for=condition=ready node --all --timeout=180s || {
    echo "Warning: Node not ready yet. This may take a few more moments."
}

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
echo "Container Images Used:"
echo "  ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo "  ${DOCKERHUB_USER}/kube-apiserver:${K8S_VERSION}"
echo "  ${DOCKERHUB_USER}/kube-controller-manager:${K8S_VERSION}"
echo "  ${DOCKERHUB_USER}/kube-scheduler:${K8S_VERSION}"
echo "  ${DOCKERHUB_USER}/kube-proxy:${K8S_VERSION}"
echo "  ${DOCKERHUB_USER}/etcd:${ETCD_VERSION}"
echo "  ${DOCKERHUB_USER}/coredns:${COREDNS_VERSION}"
echo "  ${DOCKERHUB_USER}/flannel:${FLANNEL_VERSION}"
echo "  ${DOCKERHUB_USER}/flannel-cni-plugin:latest"
echo "============================================"
echo ""
echo "Useful Commands:"
echo "  kubectl get nodes                  # Check node status"
echo "  kubectl get pods -A                # Check all pods"
echo "  sudo systemctl status kubelet      # Check kubelet service"
echo "  sudo journalctl -u kubelet -f      # View kubelet logs"
echo "  kubectl logs -n kube-flannel -l app=flannel  # View Flannel logs"
echo "============================================"