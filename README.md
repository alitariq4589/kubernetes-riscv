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
### Remove/Replace the already installed Kubernetes (optional)

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
sudo cp ~/k8s-custom/bin/kubectl /usr/bin/
sudo cp ~/k8s-custom/bin/kubeadm /usr/bin/
sudo cp ~/k8s-custom/bin/kubelet /usr/bin/
sudo cp ~/k8s-custom/bin/kube-proxy /usr/bin/
sudo cp ~/k8s-custom/bin/kube-apiserver /usr/bin/
sudo cp ~/k8s-custom/bin/kube-controller-manager /usr/bin/
sudo cp ~/k8s-custom/bin/kube-scheduler /usr/bin/

# Set proper permissions
sudo chmod +x /usr/bin/kube*
```


# Complete guide for setting up Kubernetes with Flannel

Use this guide after you have installed the binaries and set them up using above commands. This sets up Kubernetes with Control plane on x86 and worker nodes on riscv64

## Images

The releases for kubernetes and flannel are built and uploaded on dockerhub:
- `cloudv10x/pause:3.10` (amd64 + riscv64)
- `cloudv10x/flannel:0.28.0` (amd64 + riscv64)

These are available at: https://github.com/alitariq4589/kubernetes-riscv/releases

## Scripts Provided

1. **control-plane-setup-x86.sh** - Sets up x86 control plane with custom images
2. **worker-node-setup.sh** - Sets up worker nodes (x86 or RISC-V) with custom images
3. **cleanup.sh** - Complete cleanup of Kubernetes installation

## Quick Start

### Step 1: Set Up Control Plane

##### For x86:

```bash
# Download the script
wget https://raw.githubusercontent.com/alitariq4589/kubernetes-riscv/main/scripts/control-plane-setup-x86.sh
chmod +x control-plane-setup-x86.sh

# Run it
./control-plane-setup-x86.sh
```

The script will:
- Clean up any existing Kubernetes installation
- Install and configure containerd with your custom pause image
- Install Kubernetes
- Initialize the control plane
- Install Flannel via Helm with your custom images


##### For riscv64:

```bash
# Download the script
wget https://raw.githubusercontent.com/alitariq4589/kubernetes-riscv/main/scripts/control-plane-setup-riscv64.sh
chmod +x control-plane-setup-riscv64.sh

# Run it
./control-plane-setup-riscv64.sh
```

The script will:
- Clean up any existing Kubernetes installation
- Install and configure containerd with your custom pause image
- Install Kubernetes
- Initialize the control plane
- Install Flannel via Helm with your custom images

### Step 2: Get Join Command

At the end of the control plane setup, you'll see a join command like:

```
kubeadm join 192.168.20.59:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz...
```

Copy this entire command.

### Step 3: Set Up Worker Nodes

**On each worker node (RISC-V or x86):**

```bash
# Download the script
wget https://raw.githubusercontent.com/alitariq4589/kubernetes-riscv/main/scripts/worker-node-setup.sh
chmod +x worker-node-setup.sh

# Run it with the join command
./worker-node-setup.sh kubeadm join 192.168.20.59:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz...
```

The script will:
- Detect architecture (x86_64 or riscv64)
- Clean up any existing installation
- Install and configure containerd with your custom pause image
- Install Kubernetes (from repos for x86, from your release for RISC-V)
- Join the cluster

### Step 4: Verify

**On control plane:**

```bash
# Check all nodes are Ready
kubectl get nodes

# Should show something like:
# NAME              STATUS   ROLES           AGE   VERSION
# phantom-machine   Ready    control-plane   5m    v1.31.x
# sf2-1             Ready    <none>          2m    v1.35.0
# sf2-2             Ready    <none>          2m    v1.35.0
# sf2-3             Ready    <none>          2m    v1.35.0

# Check Flannel pods
kubectl get pods -n kube-flannel -o wide

# Should show one pod per node, all Running
```

## Troubleshooting

### Issue: Nodes show NotReady

**Check pause image on ALL nodes:**
```bash
sudo grep sandbox_image /etc/containerd/config.toml
# Should show: sandbox_image = "alitariq4589/pause:3.10"
```

**If wrong, fix it:**
```bash
sudo sed -i 's|sandbox_image = .*|sandbox_image = "alitariq4589/pause:3.10"|g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

### Issue: Flannel pods not starting

**Check Flannel logs:**
```bash
kubectl logs -n kube-flannel -l app=flannel
```

**Check Flannel pod on specific node:**
```bash
kubectl get pods -n kube-flannel -o wide
kubectl logs -n kube-flannel <pod-name>
```

### Issue: Pods stuck in ContainerCreating

This usually means the pause container is the issue.

**On the affected node:**
```bash
# Check kubelet logs
sudo journalctl -u kubelet -n 50 | grep -i pause

# Should NOT see errors about "no match for platform"
# If you do, the pause image is wrong
```

### Issue: Want to start fresh

**On any node:**
```bash
./cleanup.sh
# Then reboot
sudo reboot
```

## What Makes This Work

### The Critical Configuration

The key to making RISC-V work is **two things**:

1. **Custom pause container** configured in containerd:
```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "alitariq4589/pause:3.10"
```

2. **Custom Flannel image** via Helm:
```bash
helm install flannel \
  --set image.repository="alitariq4589/flannel" \
  --set image.tag="0.28.0" \
  flannel/flannel
```

### Why This Approach Works

- **Multi-arch images**: Your images support both amd64 and riscv64
- **Docker automatically selects**: The right architecture is pulled automatically
- **Helm makes it easy**: No need to manually edit manifests
- **Everything is standard**: No modifications to Kubernetes source code needed

## Network Architecture

```
Control Plane (x86):
├── containerd → cloudv10x/pause:3.10 (pulls amd64)
└── Flannel pod → cloudv10x/flannel:0.28.0 (pulls amd64)

Worker Nodes (RISC-V):
├── containerd → cloudv10x/pause:3.10 (pulls riscv64)
└── Flannel pod → cloudv10x/flannel:0.28.0 (pulls riscv64)
```

## Important Notes

1. **Pause image MUST be set on ALL nodes** before joining the cluster
2. **DockerHub username must be consistent** across all scripts
3. **Flannel is installed once** on the control plane via Helm, then DaemonSet deploys to workers
4. **No Flannel systemd service needed** - everything runs as Kubernetes pods
5. **CNI plugins are in the tarball** for RISC-V nodes

## File Locations

### Control Plane (x86)
- Kubernetes binaries: `/usr/bin/`
- containerd config: `/etc/containerd/config.toml`
- kubeconfig: `~/.kube/config`

### Worker Nodes (RISC-V)
- Kubernetes binaries: `/usr/local/bin/`
- CNI plugins: `/opt/cni/bin/`
- containerd config: `/etc/containerd/config.toml`

## Verification Checklist

After setup, verify:

- [ ] All nodes show `STATUS: Ready`
- [ ] One Flannel pod per node, all `Running`
- [ ] Pause image correct on all nodes
- [ ] Can create test pod: `kubectl run test --image=busybox -- sleep 3600`
- [ ] Test pod gets IP and runs
- [ ] Pods can communicate across nodes

## Next Steps

Once your cluster is running:

1. Deploy applications
2. Test cross-architecture communication
3. Set up persistent storage if needed
4. Configure network policies
5. Monitor with kubectl top nodes/pods

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Review kubelet logs: `sudo journalctl -u kubelet -n 100`
3. Check Flannel logs: `kubectl logs -n kube-flannel -l app=flannel`
4. Verify pause image configuration on all nodes