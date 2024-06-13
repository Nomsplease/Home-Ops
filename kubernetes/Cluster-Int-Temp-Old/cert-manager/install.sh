kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.15.0 --values values.yaml