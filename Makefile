.PHONY: setup-local up configure label-node deploy-stack test info teardown

SSH_KEY  := ~/.ssh/id_hetzner_cloud
SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
KC       := KUBECONFIG=./hetzner-thesis.yaml

# Derive the server IP from Terraform state (works offline after `up`)
IP = $(shell terraform output -raw instance_public_ip 2>/dev/null)

# ── 1. Local prerequisites ────────────────────────────────────────────────────
# Install k6 locally (run once). Requires apt-based Linux.
setup-local:
	@if command -v k6 >/dev/null 2>&1; then \
		echo "k6 already installed. Skipping."; \
	else \
		echo "Installing k6..."; \
		sudo install -m 0755 -d /usr/share/keyrings; \
		sudo gpg --no-default-keyring \
			--keyring /usr/share/keyrings/k6-archive-keyring.gpg \
			--keyserver hkp://keyserver.ubuntu.com:80 \
			--recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69; \
		echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
			| sudo tee /etc/apt/sources.list.d/k6.list; \
		sudo apt-get update && sudo apt-get install -y k6; \
	fi

# ── 2. Provision the Hetzner server ──────────────────────────────────────────
up:
	terraform apply -auto-approve

# ── 3. Fetch kubeconfig (waits for k3s to be ready) ──────────────────────────
configure:
	@echo "Waiting for SSH..."
	@timeout 300 bash -c \
		'until ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) "echo ok" 2>/dev/null; \
		 do sleep 10; echo "SSH not ready..."; done'
	@echo "Waiting for cloud-init to complete..."
	@ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) "cloud-init status --wait" 2>/dev/null || \
		echo "WARNING: cloud-init may have failed — check /var/log/thesis-setup.log on the server"
	@echo "Waiting for k3s kubeconfig..."
	@until ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) \
		"[ -f /etc/rancher/k3s/k3s.yaml ]" 2>/dev/null; \
		do sleep 10; echo "Still waiting for k3s..."; done
	@echo "Fetching kubeconfig..."
	scp $(SSH_OPTS) -i $(SSH_KEY) \
		root@$(IP):/etc/rancher/k3s/k3s.yaml ./hetzner-thesis.yaml
	sed -i "s/127.0.0.1/$(IP)/g" ./hetzner-thesis.yaml
	@echo "kubeconfig saved to ./hetzner-thesis.yaml"

# ── 4. Label node with WasmEdge capability ───────────────────────────────────
label-node:
	$(KC) kubectl label node --all \
		runtime.kwasm.sh/runtime=wasmedge \
		node.kubernetes.io/wasm-runtime=wasmedge \
		--overwrite

# ── 5. Deploy observability stack and WasmEdge RuntimeClass ──────────────────
deploy-stack:
	$(KC) kubectl apply -f wasmedge-runtimeclass.yaml
	$(KC) helm repo add prometheus-community \
		https://prometheus-community.github.io/helm-charts
	$(KC) helm repo update
	$(KC) helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--namespace observability \
		--create-namespace \
		--values observability-values.yaml \
		--timeout 10m \
		--wait

# ── 6. Smoke-test: run a WASM pod and print its output ───────────────────────
test:
	$(KC) kubectl delete pod wasmedge-test --ignore-not-found
	$(KC) kubectl apply -f test-wasm.yaml
	$(KC) kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/wasmedge-test --timeout=60s || true
	$(KC) kubectl logs wasmedge-test
	$(KC) kubectl delete pod wasmedge-test --ignore-not-found

# ── 7. Show access URLs and credentials ──────────────────────────────────────
info:
	@echo ""
	@echo "=== Thesis Experiment Access Info ==="
	@echo "  Server IP  : $(IP)"
	@echo "  Grafana    : http://$(IP):32000  (admin / thesis-grafana)"
	@echo "  Prometheus : http://$(IP):32090"
	@echo "  K8s API    : https://$(IP):6443"
	@echo "  SSH        : ssh -i $(SSH_KEY) root@$(IP)"
	@echo ""
	@echo "=== Kubeconfig ==="
	@echo "  export KUBECONFIG=$(PWD)/hetzner-thesis.yaml"
	@echo ""

# ── 8. Tear down everything ───────────────────────────────────────────────────
teardown:
	terraform destroy -auto-approve
	rm -f ./hetzner-thesis.yaml
