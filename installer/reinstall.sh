#!/usr/bin/env bash

sudo kubeadm reset && rm -rf /etc/cni/net.d/* ~/.kube/config
sudo kubeadm init --config kubeadm-init.yaml
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
kubectl create -f calico-config.yaml
