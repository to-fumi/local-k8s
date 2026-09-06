.DEFAULT_GOAL := help

CP           := wfd-cp
WORKERS      := wfd-w1 wfd-w2
DOCKER_VM    := docker
KUBECTX      := kubeadm-local
BOOTSTRAP    := CP=$(CP) WORKERS="$(WORKERS)" DOCKER_VM=$(DOCKER_VM) KUBECTX=$(KUBECTX) ./bootstrap.sh
KUBECTL      := kubectl --context $(KUBECTX)
GATEWAY_NS   := istio-ingress
TUNNEL_PORT  ?= 18080
NS           ?=

.PHONY: help
help: ## コマンド一覧
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --- クラスタ ---------------------------------------------------------------

.PHONY: up
up: ## クラスタを一式立てる (VM -> kubeadm -> Cilium -> addons -> Istio -> Gateway -> レジストリ -> Argo CD)
	$(BOOTSTRAP) vms
	$(BOOTSTRAP) init
	$(BOOTSTRAP) kubeconfig
	$(BOOTSTRAP) cni
	$(BOOTSTRAP) join
	$(BOOTSTRAP) storage
	$(BOOTSTRAP) lb
	$(BOOTSTRAP) mesh
	$(BOOTSTRAP) gateway
	$(BOOTSTRAP) sealed
	$(BOOTSTRAP) docker-vm
	$(BOOTSTRAP) registry
	$(BOOTSTRAP) argocd
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

.PHONY: gateway
gateway: ## [個別] クラスタ共有の Gateway を 1 枚立てる
	$(BOOTSTRAP) gateway

.PHONY: sealed
sealed: ## [個別] Sealed Secrets controller (暗号文を git に置けるようにする)
	$(BOOTSTRAP) sealed

.PHONY: argocd
argocd: ## [個別] Argo CD + Application 定義 (レジストリの後に流すこと)
	$(BOOTSTRAP) argocd

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
# 載せる側が知るのは context / registry / 共有 Gateway の 3 つだけ。

.PHONY: addr
addr: ## 接続情報 (context と registry) を eval できる形で出す
	@$(BOOTSTRAP) addr

.PHONY: registry-addr
registry-addr: ## レジストリのアドレスだけ出す (docker VM の DHCP で変わる)
	@$(BOOTSTRAP) registry-addr

.PHONY: context
context: ## kubectl の context 名を出す
	@$(BOOTSTRAP) context

.PHONY: gateway-addr
gateway-addr: ## 共有 Gateway の LoadBalancer IP を出す
	@$(BOOTSTRAP) gateway-addr

.PHONY: tunnel
tunnel: ## 共有 Gateway への SSH トンネル (前景 / 全アプリで 1 本)
	@# user-v2 はユーザモードのネットワークなので macOS 側に LB のサブネットへの
	@# 経路がなく、また Cilium の NodePort は eBPF 処理で listen ソケットを持たないため
	@# Lima の自動ポート転送にも引っかからない。cp ノードを踏み台にして LB IP へ繋ぐ。
	@ip=$$($(BOOTSTRAP) gateway-addr 2>/dev/null); \
	if [ -z "$$ip" ]; then \
	  echo "共有 Gateway にアドレスがない: $(KUBECTL) -n $(GATEWAY_NS) get gateway" >&2; exit 1; fi; \
	echo "127.0.0.1:$(TUNNEL_PORT)  ->  $$ip:80   (Ctrl-C で終了)"; \
	echo "  振り分けは Host ヘッダで行う。例: http://what-for-dinner.localtest.me:$(TUNNEL_PORT)/docs"; \
	echo "  (*.localtest.me は公開 DNS が 127.0.0.1 を返すので /etc/hosts は要らない)"; \
	$(KUBECTL) get httproute -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames; \
	ssh -F $$HOME/.lima/$(CP)/ssh.config -N -L $(TUNNEL_PORT):$$ip:80 lima-$(CP)

# --- GitOps -----------------------------------------------------------------

.PHONY: argocd-password
argocd-password: ## Argo CD の初期 admin パスワード
	@$(BOOTSTRAP) argocd-password

.PHONY: argocd-apps
argocd-apps: ## Application の同期状況
	@$(KUBECTL) -n argocd get applications \
	    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

.PHONY: argocd-sync
argocd-sync: ## git を今すぐ引き直させる (既定のポーリングは 3 分間隔)
	@$(KUBECTL) -n argocd annotate applications --all \
	    argocd.argoproj.io/refresh=hard --overwrite

.PHONY: sealed-backup
sealed-backup: ## Sealed Secrets の秘密鍵を退避 (これを失うと既存の封は開かない)
	@out=sealed-secrets-key-$$(date +%Y%m%d%H%M%S).yaml; \
	$(KUBECTL) -n kube-system get secret \
	    -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml > $$out; \
	chmod 600 $$out; \
	echo "$$out に書き出した。**git に入れないこと** (これは平文の秘密鍵)"

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
