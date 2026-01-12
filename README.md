# kubernetes-riscv
Kubernetes Releases from official upstream repository for RISC-V. 

This repository is set up to trigger CI for periodic release. There is no change to the source code. The CI file just fetches the source code from upstream repository and builds it

This release is set up as part of RISC-V software releases provided by [Cloud-V](https://cloud-v.co).

If you have a package which you would like us to add, contact us at https://cloud-v.co/contactus or join our [Discord server](https://discord.gg/H7EGrzV93p) :)

## Installing control plane on x86

```
# Download the tarball (replace with your architecture)
wget https://github.com/alitariq4589/kubernetes-riscv/releases/download/v1.35.0/kubernetes-v1.35.0-x86_64-linux.tar.gz

# Extract to a temporary directory
mkdir -p ~/k8s-custom
tar -xzf kubernetes-v1.35.0-x86_64-linux.tar.gz -C ~/k8s-custom/

# Verify the binaries
ls -lh ~/k8s-custom/
```
### Remove/Replace the already installed Kubernetes
```
# Stop Kubernetes using systemd services (if you had installed an older version before)
sudo systemctl stop kubelet
sudo systemctl stop kube-apiserver 2>/dev/null || true
sudo systemctl stop kube-controller-manager 2>/dev/null || true
sudo systemctl stop kube-scheduler 2>/dev/null || true
sudo systemctl stop kube-proxy 2>/dev/null || true

# Remove or move old binaries
sudo rm -f /usr/bin/kubectl
sudo rm -f /usr/bin/kubeadm
sudo rm -f /usr/bin/kubelet
```

## Place binaries at appropriate place
```
# Copy new binaries
sudo cp ~/k8s-custom/kubectl /usr/bin/
sudo cp ~/k8s-custom/kubeadm /usr/bin/
sudo cp ~/k8s-custom/kubelet /usr/bin/
sudo cp ~/k8s-custom/kube-proxy /usr/bin/
sudo cp ~/k8s-custom/kube-apiserver /usr/bin/
sudo cp ~/k8s-custom/kube-controller-manager /usr/bin/
sudo cp ~/k8s-custom/kube-scheduler /usr/bin/

# Set proper permissions
sudo chmod +x /usr/bin/kube*
```