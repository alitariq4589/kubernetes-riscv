#!/bin/bash

# ============================================
# Complete Kubernetes Cleanup Script
# Run this to completely remove Kubernetes
# ============================================

echo "============================================"
echo "Kubernetes Complete Cleanup"
echo "============================================"
echo ""
echo "This will remove ALL Kubernetes components"
echo "Press Ctrl+C to cancel, or Enter to continue..."
read

set +e  # Don't exit on errors during cleanup

echo "Step 1: Stopping services..."

# Stop all Kubernetes services
sudo systemctl stop kubelet 2>/dev/null
sudo systemctl stop flanneld 2>/dev/null
sudo systemctl stop containerd 2>/dev/null

# Disable services
sudo systemctl disable kubelet 2>/dev/null
sudo systemctl disable flanneld 2>/dev/null

echo "✓ Services stopped"
echo ""

echo "Step 2: Resetting kubeadm..."

# Reset kubeadm
sudo kubeadm reset -f 2>/dev/null || true

echo "✓ Kubeadm reset"
echo ""

echo "Step 3: Removing Kubernetes components..."

# Remove Kubernetes packages (x86 only)
if [ "$(uname -m)" = "x86_64" ]; then
    sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    sudo apt-get purge -y kubelet kubeadm kubectl 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
fi

# Remove custom binaries (RISC-V or manual installs)
sudo rm -f /usr/local/bin/kubelet
sudo rm -f /usr/local/bin/kubeadm
sudo rm -f /usr/local/bin/kubectl
sudo rm -f /usr/local/bin/kube-proxy
sudo rm -f /usr/local/bin/flanneld

echo "✓ Kubernetes binaries removed"
echo ""

echo "Step 4: Removing configuration files..."

# Remove all Kubernetes directories
sudo rm -rf /etc/kubernetes/
sudo rm -rf /var/lib/kubelet/
sudo rm -rf /var/lib/etcd/
sudo rm -rf $HOME/.kube/

# Remove systemd service files
sudo rm -f /etc/systemd/system/kubelet.service
sudo rm -f /etc/systemd/system/flanneld.service
sudo rm -rf /etc/systemd/system/kubelet.service.d/

# Remove Flannel config
sudo rm -rf /etc/flannel/
sudo rm -rf /run/flannel/

sudo systemctl daemon-reload

echo "✓ Configuration files removed"
echo ""

echo "Step 5: Cleaning up networking..."

# Remove network interfaces
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete docker0 2>/dev/null || true

# Remove CNI directories
sudo rm -rf /var/lib/cni/
sudo rm -rf /etc/cni/net.d/
sudo rm -rf /opt/cni/bin/

# Flush iptables
echo "Flushing iptables rules..."
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X

echo "✓ Networking cleaned up"
echo ""

echo "Step 6: Removing containerd configuration..."

# Reset containerd config to default
if command -v containerd &> /dev/null; then
    sudo rm -f /etc/containerd/config.toml
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    sudo systemctl restart containerd 2>/dev/null || true
fi

echo "✓ Containerd reset to default"
echo ""

echo "Step 7: Removing kernel modules and sysctl settings..."

# Remove kernel module configs
sudo rm -f /etc/modules-load.d/k8s.conf

# Remove sysctl configs
sudo rm -f /etc/sysctl.d/k8s.conf

echo "✓ Kernel configs removed"
echo ""

echo "Step 8: Removing package repositories..."

# Remove Kubernetes apt source (x86 only)
if [ "$(uname -m)" = "x86_64" ]; then
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list
    sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo "✓ Package repositories removed"
echo ""

echo "Step 9: Final cleanup..."

# Remove any leftover files
sudo find /var/lib -name "*kube*" -type d -exec rm -rf {} + 2>/dev/null || true
sudo find /etc -name "*kube*" -type d -exec rm -rf {} + 2>/dev/null || true

# Clear any cached images (optional - uncomment if needed)
# sudo docker system prune -af 2>/dev/null || true

echo "✓ Final cleanup complete"
echo ""

echo "============================================"
echo "Cleanup Complete!"
echo "============================================"
echo ""
echo "Your system has been reset. You can now:"
echo "  1. Run setup-control-plane.sh for a fresh control plane"
echo "  2. Run setup-worker.sh for a fresh worker node"
echo ""
echo "Note: If you want to reinstall, you may want to reboot first:"
echo "  sudo reboot"
echo ""
echo "============================================"