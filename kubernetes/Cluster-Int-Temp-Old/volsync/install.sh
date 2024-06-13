#!/bin/bash
helm repo add backube https://backube.github.io/helm-charts/
helm repo update
helm install --create-namespace -n volsync-system volsync backube/volsync