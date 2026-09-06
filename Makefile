.DEFAULT_GOAL := help

CP           := wfd-cp
WORKERS      := wfd-w1 wfd-w2
DOCKER_VM    := docker
KUBECTX      := kubeadm-local
BOOTSTRAP    := CP=$(CP) WORKERS="$(WORKERS)" DOCKER_VM=$(DOCKER_VM) KUBECTX=$(KUBECTX) ./bootstrap.sh
KUBECTL      := kubectl --context $(KUBECTX)
NS           ?=

.PHONY: help
help: ## コマンド一覧
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- クラスタ ---------------------------------------------------------------

.PHONY: up
up: ## クラスタを一式立てる (VM -> kubeadm -> Cilium -> addons -> Istio -> レジストリ)
	$(BOOTSTRAP) vms
	$(BOOTSTRAP) init
	$(BOOTSTRAP) kubeconfig
	$(BOOTSTRAP) cni
	$(BOOTSTRAP) join
	$(BOOTSTRAP) storage
	$(BOOTSTRAP) lb
	$(BOOTSTRAP) mesh
	$(BOOTSTRAP) docker-vm
	$(BOOTSTRAP) registry
	@echo
	@$(MAKE) --no-print-directory addr

.PHONY: vms
vms: ## [個別] Lima VM を起動して VM 間通信を検証
	$(BOOTSTRAP) vms

.PHONY: init
init: ## [個別] control-plane で kubeadm init (kube-proxy なし)
	$(BOOTSTRAP) init

.PHONY: kubeconfig
kubeconfig: ## [個別] admin.conf を ~/.kube/config へマージ
	$(BOOTSTRAP) kubeconfig

.PHONY: cni
cni: ## [個別] Cilium 導入 (kube-proxy 置換 + Hubble)
	$(BOOTSTRAP) cni

.PHONY: join
join: ## [個別] worker を join
	$(BOOTSTRAP) join

.PHONY: storage
storage: ## [個別] local-path-provisioner を default SC に
	$(BOOTSTRAP) storage

.PHONY: lb
lb: ## [個別] Cilium LB IPAM + L2 広告
	$(BOOTSTRAP) lb

.PHONY: mesh
mesh: ## [個別] Gateway API CRD + Istio
	$(BOOTSTRAP) mesh

.PHONY: docker-vm
docker-vm: ## [個別] ビルド用 docker VM を用意してクラスタと同じ網に繋ぐ
	$(BOOTSTRAP) docker-vm

.PHONY: registry
registry: ## [個別] レジストリ起動 + 全ノードの containerd に登録
	$(BOOTSTRAP) registry

.PHONY: status
status: ## ノード / Cilium / Istio の状態
	$(BOOTSTRAP) status

.PHONY: down
down: ## VM を止める (クラスタの中身は残る)
	@for n in $(CP) $(WORKERS) $(DOCKER_VM); do limactl stop $$n || true; done

.PHONY: destroy
destroy: ## VM ごと消す
	@for n in $(CP) $(WORKERS); do limactl delete -f $$n || true; done

# --- アプリ側リポジトリが使う接続点 ------------------------------------------
# 載せる側はこの 2 つだけ知っていればいい。

.PHONY: addr
addr: ## 接続情報 (context と registry) を eval できる形で出す
	@$(BOOTSTRAP) addr

.PHONY: registry-addr
registry-addr: ## レジストリのアドレスだけ出す (docker VM の DHCP で変わる)
	@$(BOOTSTRAP) registry-addr

.PHONY: context
context: ## kubectl の context 名を出す
	@$(BOOTSTRAP) context

# --- 観測 -------------------------------------------------------------------

.PHONY: hubble-ui
hubble-ui: ## Hubble UI を開く (eBPF で拾ったフロー)
	cilium hubble ui

.PHONY: hubble-watch
hubble-watch: ## フローを流し見る (NS=<namespace> で絞れる)
	@cilium hubble port-forward & \
	sleep 3; \
	if [ -n "$(NS)" ]; then hubble observe --namespace $(NS) -f; \
	else hubble observe -f; fi

.PHONY: ebpf
ebpf: ## Service が eBPF マップにどう載っているかを見る
	@echo "=== cilium が把握している Service ==="
	@$(KUBECTL) -n kube-system exec ds/cilium -- cilium-dbg service list
	@echo; echo "=== eBPF のロードバランサマップ ==="
	@$(KUBECTL) -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | head -20
	@echo; echo "=== ノードに載っている eBPF prog / map の数 ==="
	@printf "  prog: "; limactl shell $(CP) -- sudo bpftool prog show | grep -c .
	@printf "  map:  "; limactl shell $(CP) -- sudo bpftool map show | grep -cE '^[0-9]+:'
