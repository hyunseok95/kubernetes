#!/usr/bin/env bash

sudo kubeadm reset && rm -rf /etc/cni/net.d/* ~/.kube/config
sudo kubeadm join --config kubeadm-join.yaml -v 5
