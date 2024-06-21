#!/bin/bash
kubectl apply -f namespace.yaml
sops -d age-key.secret.sops.yaml | kubectl apply -f -
sops -d github-deploy-key.secret.sops.yaml | kubectl apply -f -
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
kubectl apply -k ../../resources/