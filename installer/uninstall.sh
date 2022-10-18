#!/bin/bash

main() {
  sudo kubeadm reset
  sudo rm -rf /etc/cni/net.d
  sudo rm -rf /root/.kube/config
  sudo rm -rf /home/"$(logname)"/.kube/config
}

main "$@"
