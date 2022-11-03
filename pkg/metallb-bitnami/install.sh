#!/usr/bin/env bash

helm repo add bitnami https://charts.bitnami.com/bitnami

helm repo update

helm install metallb bitnami/metallb \
--namespace=metallb-system \
--create-namespace \
-f $HOME/workspace/k8s/metallb-bitnami/config.yaml