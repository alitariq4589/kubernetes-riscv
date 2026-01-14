#!/bin/bash

# ============================================
# Worker Node Setup (x86 or RISC-V)
# ============================================

# Configuration - MUST MATCH CONTROL PLANE!
DOCKERHUB_USER="cloudv10x"  # Your DockerHub username
PAUSE_VERSION="3.10"
K8S_VERSION="v1.35.0"  # Version of your custom RISC-V binaries
K8S_TARBALL_URL="https://github.com/alitariq4589/kubernetes-riscv/releases/download/${K8S_VERSION}/kubernetes-${K8S_VERSION}-riscv64-linux.tar.gz"

# Get join command from argument
JOIN_COMMAND="$@"

if [ -z "$JOIN_COMMAND" ]; then
  echo "ERROR: No join command provided"
  echo ""
  echo "Usage: ./setup-worker.sh <join-command>"
  echo ""
  echo "Example:"
  echo "  ./setup-worker.sh kubeadm join 192.168.20.59:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz..."
  echo ""
  echo "Get the join command from your control plane:"
  echo "  sudo kubeadm token create --print-join-command"
  exit 1
fi

set -e  # Exit on any error

echo "============================================"
echo "Kubernetes Worker Node Setup"
echo "============================================"
echo ""
echo "Using custom pause image:"
echo "  ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo ""

# Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
echo ""

# --- CLEANUP SECTION ---
echo "Step 1: Cleaning up existing configuration..."

# Stop any running services
sudo systemctl stop kubelet 2>/dev/null || true
sudo systemctl stop flanneld 2>/dev/null || true

# Reset kubeadm
sudo kubeadm reset -f 2>/dev/null || true

# Remove configuration
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/

# Cleanup networking
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo rm -rf /var/lib/cni/
sudo rm -rf /etc/cni/net.d/*

# Remove Flannel systemd service (from previous attempts)
sudo systemctl disable flanneld 2>/dev/null || true
sudo rm -f /etc/systemd/system/flanneld.service
sudo rm -f /run/flannel/subnet.env
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

sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y containerd conntrack ethtool socat ebtables apt-transport-https ca-certificates curl gpg

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

echo "✓ Containerd configured with custom pause image"
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

if [ "$ARCH" = "x86_64" ]; then
    echo "Installing Kubernetes for x86_64 from official repos..."
    
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    
elif [ "$ARCH" = "riscv64" ]; then
    echo "Installing Kubernetes for RISC-V from custom binaries..."
    
    # Check if binaries already installed
    if [ -f /usr/local/bin/kubelet ] && [ -f /usr/local/bin/kubeadm ] && [ -f /usr/local/bin/kubectl ]; then
        echo "Kubernetes binaries already installed in /usr/local/bin/"
    else
        echo "Downloading Kubernetes ${K8S_VERSION} for RISC-V..."
        
        cd /tmp
        rm -rf kubernetes-riscv-install
        mkdir -p kubernetes-riscv-install
        cd kubernetes-riscv-install
        
        wget -q "${K8S_TARBALL_URL}" -O kubernetes.tar.gz
        tar -xzf kubernetes.tar.gz
        
        # Run the install script
        if [ -f install.sh ]; then
            sudo bash install.sh
        else
            # Manual installation if install.sh doesn't exist
            echo "Installing binaries manually..."
            sudo cp -r bin/* /usr/local/bin/ 2>/dev/null || sudo cp kube* /usr/local/bin/
            sudo chmod +x /usr/local/bin/kube*
            
            # Install CNI plugins
            sudo mkdir -p /opt/cni/bin
            sudo cp -r cni/* /opt/cni/bin/ 2>/dev/null || true
            sudo chmod +x /opt/cni/bin/* 2>/dev/null || true
        fi
        
        cd /tmp
        rm -rf kubernetes-riscv-install
    fi
    
    # Verify installation
    if [ ! -f /usr/local/bin/kubelet ]; then
        echo "ERROR: kubelet not found in /usr/local/bin/"
        echo "Please install Kubernetes binaries first"
        exit 1
    fi
    
    echo "Kubernetes binaries installed:"
    ls -lh /usr/local/bin/kube*
    
else
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
fi

echo "✓ Kubernetes installed"
echo ""

# --- CREATE KUBELET SERVICE (for RISC-V) ---
if [ "$ARCH" = "riscv64" ]; then
    echo "Step 4: Setting up kubelet service for RISC-V..."
    
    sudo tee /etc/systemd/system/kubelet.service > /dev/null <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo mkdir -p /etc/systemd/system/kubelet.service.d
    sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf > /dev/null <<EOF
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable kubelet
    
    echo "✓ Kubelet service configured"
    echo ""
fi

# --- JOIN CLUSTER ---
echo "Step 5: Joining the cluster..."
echo "Running: sudo $JOIN_COMMAND"
echo ""

sudo $JOIN_COMMAND

echo ""
echo "✓ Node joined successfully"
echo ""

# Wait a moment for kubelet to start
sleep 5

# --- VERIFY ---
echo "Step 6: Verifying setup..."
echo ""

echo "Kubelet status:"
sudo systemctl status kubelet --no-pager -l | head -20
echo ""

echo "Pause image configuration:"
sudo grep sandbox_image /etc/containerd/config.toml
echo ""

echo "CNI plugins installed:"
ls -lh /opt/cni/bin/ | head -10
echo ""

echo "============================================"
echo "✓ Worker Node Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "1. On control plane, check nodes:"
echo "   kubectl get nodes"
echo ""
echo "2. Check Flannel pods:"
echo "   kubectl get pods -n kube-flannel -o wide"
echo ""
echo "3. If you see pause container errors:"
echo "   - Verify: sudo grep sandbox_image /etc/containerd/config.toml"
echo "   - Should show: ${DOCKERHUB_USER}/pause:${PAUSE_VERSION}"
echo "   - Restart: sudo systemctl restart containerd && sudo systemctl restart kubelet"
echo ""
echo "4. Monitor kubelet logs:"
echo "   sudo journalctl -u kubelet -f"
echo ""
echo "============================================"