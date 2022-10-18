#!/usr/bin/env bash
#
# Perform installation of Kubernetes

K8S_SERVER_IP=''
K8S_INSTALL_TYPE=''
GW_TOKEN_HASH=''

KUBERNETES_VERSION='v1.23.0'
KUBELET_CONFIG_VERSION='v0.4.0'
CONTAINERD_VERSION='v1.6.8'
CNI_PLUGINS_VERSION='v1.1.1'
CRICTL_VERSION='v1.23.0'
RUNC_VERSION='v1.1.3'

ARCH="$(uname -m)"
case "${ARCH}" in
aarch64)
  ARCH=arm64
  ;;
x86_64)
  ARCH=amd64
  ;;
esac

DISTRO=''
if [[ -n "$(dpkg --version 2>/dev/null)" ]]; then
  DISTRO='debian'
elif [[ -n $(rpm --version 2>/dev/null) ]]; then
  DISTRO='redhat'
fi

################################
# Pre-check before installation
# Globals:
#   ARCH
#   DISTRO
# Arguments:
#   None
# Outputs:
#   None
################################
pre_check() {
  declare -a deb_required_package_list
  declare -a rpm_required_package_list
  declare -a target_package_list

  deb_required_package_list=(tar curl sed socat conntrack)
  rpm_required_package_list=(tar curl sed socat conntrack-tools)

  info "Pre-checking..."

  # check root permission
  if [[ "$(id -u)" -ne 0 ]] || [[ "$(id -g)" -ne 0 ]]; then
    error "To install Kubernetes, you need root privileges. \nRun the following command: \n\n sudo ./install.sh"
    exit 1
  fi

  # check machine architecture
  if [[ "${ARCH}" != "arm64" ]] && [[ "${ARCH}" != "amd64" ]]; then
    error "Unsupported architecture"
    exit 1
  fi

  # check dependency package installation
  case "${DISTRO}" in
    debian)
      for deb_required_package in "${deb_required_package_list[@]}"; do
        if [ -z "$(dpkg --get-selections "$deb_required_package" 2>/dev/null)" ]; then
          target_package_list+=("${deb_required_package}")
        fi
      done
      ;;
    redhat)
      for rpm_required_package in "${rpm_required_package_list[@]}"; do
        if [ -z "$(rpm -qa "$rpm_required_package" 2>/dev/null)" ]; then
          target_package_list+=("${rpm_required_package}")
        fi
      done
      ;;
    *)
      error "Unsupported linux distribution"
      ;;
  esac
  if [[ "${#target_package_list[@]}" -ne 0 ]]; then
    error "To install Kubernetes, you need to install some packages. \nList of packages that need to be installed :"
    for target_package in "${target_package_list[@]}"; do
      echo "  $target_package"
    done
    echo ''
    exit 1
  fi
}

##########################
# Read values and set env
# Globals:
#   K8S_SERVER_IP
#   K8S_INSTALL_TYPE
#   GW_TOKEN_HASH
# Arguments:
#   None
# Outputs:
#   None
##########################
set_env() {
  local server_ip
  server_ip=$(ip route get "$(ip route show 0.0.0.0/0 \
    | awk -F via '{ print $2 }' | awk '{ print $1 }')" \
    | awk -F src '{ print $2 }' | awk '{ print $1 }')

  info "Set environment variables to install Kubernetes. \nDefault values are assigned automatically."

  read -rp "1. Enter your server address [ $server_ip ]: " K8S_SERVER_IP
  K8S_SERVER_IP=${K8S_SERVER_IP:-$server_ip}
  read -rp "2. Enter install type either init or join [ init ]: " K8S_INSTALL_TYPE
  K8S_INSTALL_TYPE=${K8S_INSTALL_TYPE:-"init"}
  if [[ "$K8S_INSTALL_TYPE" != "init" ]] && [[ "$K8S_INSTALL_TYPE" != "join" ]]; then
    error "Please enter either init or join"
    exit 1
  elif [ "$K8S_INSTALL_TYPE" = "join" ]; then
    read -rsp "3. Enter server token's hash (sha256: 55064baf...): " GW_TOKEN_HASH && echo
  fi
  echo
}

####################################
# Configure settings for Kubernetes
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   None
#####################################
configure() {
  info "Configuration ..."

  # Swap disabled for the kubelet to work properly
  sudo swapoff -a
  sudo cp /etc/fstab /etc/fstab.old 
  sudo awk '{ 
    if ($0 ~ /.*swap.*/ && $0 !~ /^#/) {
      print "# You MUST disable swap in order for the kubelet to work properly.\n# "$0;
    } else {
      print $0;
    }
  }' /etc/fstab.old | sudo sed -n 'w /etc/fstab'
  
  # Forwarding IPv4 and letting iptables see bridged traffic
  cat <<EOF | sudo sed -n 'w /etc/modules-load.d/k8s.conf'
overlay
br_netfilter
EOF
  sudo modprobe overlay
  sudo modprobe br_netfilter

  # edit sysctl config for node's iptables
  cat <<EOF | sudo sed -n 'w /etc/sysctl.d/k8s.conf'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system >/dev/null 2>&1

  # add path /usr/local/bin at sudo env
  sudo cp /etc/sudoers /etc/sudoers.old
  sudo awk '{ 
    if ($0 ~ /secure_path/ && $1 !~ /^#/) {
      if ($NF ~ /".*"/) {
        if ($NF !~ /\/usr\/local\/sbin/) {
          $NF = gensub(/"(.+)"/, "\"\\1:/usr/local/sbin\"", 1, $NF);
        } 
        if ($NF !~ /\/usr\/local\/bin/) {
          $NF = gensub(/"(.+)"/, "\"\\1:/usr/local/bin\"", 1, $NF);
        }
      } else {
        if ($NF !~ /\/usr\/local\/sbin/) {
          $NF = gensub(/(.+)/, "\\1:/usr/local/sbin", 1, $NF);
        } 
        if ($NF !~ /\/usr\/local\/bin/) {
          $NF = gensub(/(.+)/, "\\1:/usr/local/bin", 1, $NF);
        }
      }
    }
    print $0;
  }' /etc/sudoers.old | sudo sed -n 'w /etc/sudoers'
}

##############################################
# Install and configure the container runtime.
# Globals:
#   ARCH
#   CONTAINERD_VERSION
#   RUNC_VERSION
#   CNI_PLUGINS_VERSION
# Arguments:
#   None
# Outputs:
#   None
##############################################
container_runtime() {
  info "Container runtime installation"

  # install cni plugin
  info "Install cni plugin:${CNI_PLUGINS_VERSION}"
  sudo mkdir -p /opt/cni/bin
  curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
    | sudo tar Cxz /opt/cni/bin

  # install runc
  if [[ -n $(which runc) ]] ; then
    skip "Skip install runc:${RUNC_VERSION} \n\n  Current runc version: \n  >> $(runc --v | sed -n '1p')"
  else
    info "Install runc:${RUNC_VERSION}"
    curl -Lo runc "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}"
    sudo install -m 755 runc /usr/local/sbin/runc && sudo rm -rf runc
  fi

  # install containerd
  if [[ -n $(which containerd) ]] ; then
    skip "Skip install containerd:${CONTAINERD_VERSION} \n\n  Current containerd version: \n  >> $(containerd -v)"
  else
    info "Install containerd:${CONTAINERD_VERSION}"
    curl -L "https://github.com/containerd/containerd/releases/download/${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION/v/}-linux-${ARCH}.tar.gz" \
      | sudo tar Cxz /usr/local

    # Configure containerd via systemd
    sudo mkdir -p /usr/local/lib/systemd/system
    curl -sSL "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" \
      | sudo sed -n 'w /usr/local/lib/systemd/system/containerd.service'

    # enable cri plugin and configure at containerd
    sudo mkdir -p /etc/containerd
    sudo containerd config default \
      | sed 's/\(max_container_log_line_size = \).*/\1-1/' \
      | sed 's/\(SystemdCgroup = \).*/\1true/' \
      | sudo sed -n 'w /etc/containerd/config.toml'

    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd
  fi
}

#######################################
# Install and configure the kubernetes
# Globals:
#   ARCH
#   CRICTL_VERSION
#   KUBERNETES_VERSION
#   KUBELET_CONFIG_VERSION
# Arguments:
#   None
# Outputs:
#   None
#######################################
kubernetes() {
  info "Kubernetes installation"

  # install and config crictl
  info "Install crictl:${CRICTL_VERSION}"
  curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
    | sudo tar Cxz /usr/local/bin
  cat <<EOF | sudo sed -n 'w /etc/crictl.yaml'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: true
pull-image-on-create: true
EOF

  # install kubectl kubelet kubeadm
  for kube_item in kubeadm kubelet kubectl; do
    info "Install ${kube_item}:${KUBERNETES_VERSION}"
    sudo curl -Lo /usr/local/bin/"$kube_item" \
      "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/$kube_item"
    sudo chmod +x /usr/local/bin/"$kube_item"
  done

  # config kubelet via systemd
  sudo mkdir -p /usr/local/lib/systemd/system/kubelet.service.d
  curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" \
    | awk '{ print gensub(/\/usr\/bin/, "/usr/local/bin", "g", $0);}' \
    | sudo sed -n 'w /usr/local/lib/systemd/system/kubelet.service'
  curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${KUBELET_CONFIG_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" \
    | awk '{ print gensub(/\/usr\/bin/, "/usr/local/bin", "g", $0);}' \
    | sudo sed -n 'w /usr/local/lib/systemd/system/kubelet.service.d/10-kubeadm.conf'

  sudo systemctl daemon-reload
  sudo systemctl enable --now kubelet
}

#################################
# Configure a Kubernetes cluster
# Globals:
#   K8S_SERVER_IP
#   K8S_INSTALL_TYPE
#   GW_TOKEN_HASH
# Arguments:
#   File:
#    - kubeadm-init.yaml
#    - kubeadm-join.yaml
# Outputs:
#   None
#################################
clustering() {
  info "Kubernetes Clustering"

  case "${K8S_INSTALL_TYPE}" in
  init)
    info "Init the Control Plane"

    # kubeadm init
    cp kubeadm-init.yaml kubeadm-init.yaml.old 
    sed "s/\(controlPlaneEndpoint: \).*/\1${K8S_SERVER_IP}:6443/" kubeadm-init.yaml.old | sudo sed -n 'w kubeadm-init.yaml'
    sudo kubeadm init --config kubeadm-init.yaml -v 5

    # To make kubectl work for root user
    mkdir -p /root/.kube
    sudo cp -i /etc/kubernetes/admin.conf /root/.kube/config
    sudo chown root:root /root/.kube/config

    # To make kubectl work for non-root user ( shell login )
    sudo mkdir -p /home/"$(logname)"/.kube
    sudo cp -i /etc/kubernetes/admin.conf /home/"$(logname)"/.kube/config
    sudo chown "$(logname)":"$(logname)" /home/"$(logname)"/.kube/config

    # install addon for Pod networking (choose calico)
    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml" && sleep 5
    kubectl create -f calico-config.yaml

    info "Kubernetes installation is complete. \n\nRun the following command : \n  kubectl get pods -o wide -A"
    ;;
  join)
    info "Join to Control Plane"

    # kubeadm join
    sed -i "s/\(apiServerEndpoint: \).*/\1${K8S_SERVER_IP}:6443/" kubeadm-join.yaml
    sed -i "s/- sha256:.*/- ${GW_TOKEN_HASH}/" kubeadm-join.yaml
    sudo kubeadm join --config kubeadm-join.yaml -v 5

    info "The current node has successfully joined the cluster. "
    ;;
  *)
    error "Unsupported cluster type"
    ;;
  esac
}

info() {
  echo -e "\e[0m[\e[32mINFO\e[0m]: $*\n" >&1
  sleep 1
}

skip() {
  echo -e "\e[0m[\e[33mSKIP\e[0m]: $*\n" >&1
  sleep 1
}

error() {
  echo -e "\e[0m[\e[31mERROR\e[0m]: $*\n" >&1
  sleep 1
}

main() {
  info "Start the Kubernetes installation."

  pre_check

  set_env

  configure

  container_runtime

  kubernetes

  clustering
}

main "$@"
