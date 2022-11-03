#!/usr/bin/env bash

helm upgrade metallb bitnami/metallb \
-f $HOME/workspace/k8s/config.yaml