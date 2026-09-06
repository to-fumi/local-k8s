#!/usr/bin/env bash
#
# kubeadm クラスタを段階的に組み立てる。Makefile から 1 ステップずつ呼ばれる。
# 途中で失敗したら、そのステップだけ再実行すればいい形にしてある。
#
#   ./k8s/cluster/bootstrap.sh <step>
#
# step:
#   vms         Lima VM (cp + worker x2) を起動する
#   init        control-plane で kubeadm init (kube-proxy は入れない)
#   kubeconfig  admin.conf をホストに取り出して ~/.kube/config へマージ
#   cni         Cilium を入れる (kube-proxy 置換 + Hubble + L2 announcements)
#   join        worker を join させる
#   storage     local-path-provisioner を default StorageClass として入れる
#   lb          Cilium LB IPAM のプールと L2 広告ポリシーを適用
#   mesh        Gateway API CRD + Istio (sidecar)
#   registry    ローカルレジストリを docker VM に立てる
#   status      各レイヤの状態を出す
#
set -euo pipefail

CP=${CP:-wfd-cp}
WORKERS=${WORKERS:-"wfd-w1 wfd-w2"}
DOCKER_VM=${DOCKER_VM:-docker}
LIMA_NET=${LIMA_NET:-lima:user-v2}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIMA_TMPL=${LIMA_TMPL:-$SCRIPT_DIR/lima-node.yaml}
KUBECTX=${KUBECTX:-kubeadm-local}
POD_CIDR=${POD_CIDR:-10.244.0.0/16}
CILIUM_VERSION=${CILIUM_VERSION:-1.20.1}
ISTIO_VERSION=${ISTIO_VERSION:-1.31.0}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.6.2}
LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION:-v0.0.31}
# user-v2 のサブネットは 192.168.104.0/24。DHCP と衝突しない上位を LoadBalancer に回す。
LB_POOL=${LB_POOL:-192.168.104.240/28}

KUBECTL="kubectl --context ${KUBECTX}"

# --- ヘルパ ---------------------------------------------------------------

# user-v2 ネットワーク上の IP。slirp 側 (eth0 = 192.168.5.15) は全 VM で同じ値になるので、
# kubelet の --node-ip には必ずこちらを使う。ここを間違えると全ノードが同じ IP で登録される。
node_ip() {
  limactl shell "$1" -- ip -4 -o addr show \
    | awk '$4 ~ /^192\.168\.104\./ {print $4}' | cut -d/ -f1 | head -1
}

node_dev() {
  limactl shell "$1" -- ip -4 -o addr show \
    | awk '$4 ~ /^192\.168\.104\./ {print $2}' | head -1
}

require_ip() {
  local vm="$1" ip
  ip=$(node_ip "$vm" || true)
  if [ -z "$ip" ]; then
    echo "ERROR: ${vm} に user-v2 (192.168.104.0/24) の IP がない。" >&2
    echo "       --network ${LIMA_NET} を付けて作成したか確認すること。" >&2
    exit 1
  fi
  echo "$ip"
}

# --- ステップ -------------------------------------------------------------

step_vms() {
  for n in $CP $WORKERS; do
    if limactl list -q 2>/dev/null | grep -qx "$n"; then
      echo "==> ${n}: 既存インスタンスを起動"
      limactl start "$n" --tty=false
    else
      echo "==> ${n}: 新規作成して起動"
      limactl start --name "$n" --network "$LIMA_NET" --tty=false "$LIMA_TMPL"
    fi
  done

  echo "==> VM 間通信の確認 (user-v2)"
  local cp_ip
  cp_ip=$(require_ip "$CP")
  for w in $WORKERS; do
    local w_ip
    w_ip=$(require_ip "$w")
    echo "    ${CP}(${cp_ip}) -> ${w}(${w_ip})"
    limactl shell "$CP" -- ping -c 2 -W 2 "$w_ip" >/dev/null \
      || { echo "ERROR: ${CP} から ${w} に到達できない。user-v2 が効いていない。" >&2; exit 1; }
  done
  echo "==> OK: 全ノードが相互に到達できる"
}

step_init() {
  if limactl shell "$CP" -- test -e /etc/kubernetes/admin.conf 2>/dev/null; then
    echo "==> すでに kubeadm init 済み (skip)"
    return
  fi
  local cp_ip
  cp_ip=$(require_ip "$CP")
  echo "==> kubeadm init on ${CP} (${cp_ip})"

  limactl shell "$CP" -- sudo tee /etc/kubeadm-config.yaml >/dev/null <<EOF
kind: InitConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
localAPIEndpoint:
  advertiseAddress: "${cp_ip}"
  bindPort: 6443
nodeRegistration:
  name: "${CP}"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${cp_ip}"
---
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta4
apiServer:
  certSANs:
    # Lima がゲストの 6443 をホストの 127.0.0.1 に転送するので、
    # ホストから叩くために 127.0.0.1 を証明書に入れておく
    - "127.0.0.1"
    - "${cp_ip}"
networking:
  podSubnet: "${POD_CIDR}"
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF

  # kube-proxy は入れない。Cilium が eBPF で置き換えるため。
  limactl shell "$CP" -- sudo kubeadm init \
    --config /etc/kubeadm-config.yaml \
    --skip-phases=addon/kube-proxy
}

step_kubeconfig() {
  local tmp
  tmp=$(mktemp)
  limactl shell "$CP" -- sudo cat /etc/kubernetes/admin.conf > "$tmp"
  # Lima のポート転送でホストの 127.0.0.1:6443 に出ているのでそこを向ける
  sed -i '' -E 's|server: https://[^ ]*:6443|server: https://127.0.0.1:6443|' "$tmp"
  kubectl --kubeconfig "$tmp" config rename-context kubernetes-admin@kubernetes "$KUBECTX" >/dev/null

  mkdir -p "$HOME/.kube"
  touch "$HOME/.kube/config"
  KUBECONFIG="$HOME/.kube/config:$tmp" kubectl config view --flatten > "$HOME/.kube/config.merged"
  mv "$HOME/.kube/config.merged" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  rm -f "$tmp"
  kubectl config use-context "$KUBECTX"
  echo "==> context '${KUBECTX}' を使う設定にした"
  $KUBECTL get nodes
}

step_cni() {
  local cp_ip
  cp_ip=$(require_ip "$CP")
  echo "==> Cilium ${CILIUM_VERSION} を導入 (kube-proxy 置換)"
  # kube-proxy がないので、Cilium 自身が API server へ直接繋ぐ宛先を知る必要がある
  cilium install --version "$CILIUM_VERSION" \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$cp_ip" \
    --set k8sServicePort=6443 \
    --set ipam.mode=kubernetes \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="$POD_CIDR" \
    --set autoDirectNodeRoutes=true \
    --set bpf.masquerade=true \
    --set l2announcements.enabled=true \
    --set k8sClientRateLimit.qps=50 \
    --set k8sClientRateLimit.burst=100 \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
  # ここでは Cilium 本体 (agent / operator) が立つところまでを見る。
  # hubble-relay / hubble-ui は control-plane の NoSchedule テイントで
  # worker が join するまで Pending のままなので、全体の待ちは join 側でやる。
  $KUBECTL -n kube-system rollout status daemonset/cilium --timeout=300s
  $KUBECTL -n kube-system rollout status deployment/cilium-operator --timeout=300s
}

step_join() {
  local join_cmd
  join_cmd=$(limactl shell "$CP" -- sudo kubeadm token create --print-join-command)
  for w in $WORKERS; do
    if $KUBECTL get node "$w" >/dev/null 2>&1; then
      echo "==> ${w}: すでに join 済み (skip)"
      continue
    fi
    local w_ip
    w_ip=$(require_ip "$w")
    echo "==> ${w} (${w_ip}) を join"
    # kubeadm の systemd drop-in が /etc/default/kubelet を読むので、そこで node-ip を渡す
    limactl shell "$w" -- sudo sh -c "echo 'KUBELET_EXTRA_ARGS=--node-ip=${w_ip}' > /etc/default/kubelet"
    limactl shell "$w" -- sudo $join_cmd --node-name "$w"
  done
  echo "==> 全ノードが Ready になるのを待つ"
  $KUBECTL wait --for=condition=Ready node --all --timeout=300s
  # worker に置き場ができたので、ここで Cilium 全体 (Hubble 含む) を待つ
  cilium status --wait
  $KUBECTL get nodes -o wide
}

step_storage() {
  echo "==> local-path-provisioner ${LOCAL_PATH_VERSION}"
  $KUBECTL apply -f \
    "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  $KUBECTL patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  $KUBECTL get sc
}

step_lb() {
  local dev
  dev=$(node_dev "$CP")
  echo "==> Cilium LB IPAM (${LB_POOL}) / L2 広告 (interface: ${dev})"
  # API グループのバージョンは Cilium のリリースで動くので実物から拾う
  local pool_api l2_api
  pool_api=$($KUBECTL api-resources --api-group=cilium.io 2>/dev/null \
    | awk '/CiliumLoadBalancerIPPool/ {print $3}' | head -1)
  l2_api=$($KUBECTL api-resources --api-group=cilium.io 2>/dev/null \
    | awk '/CiliumL2AnnouncementPolicy/ {print $3}' | head -1)
  : "${pool_api:=cilium.io/v2}"
  : "${l2_api:=cilium.io/v2}"

  $KUBECTL apply -f - <<EOF
apiVersion: ${pool_api}
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - cidr: "${LB_POOL}"
---
apiVersion: ${l2_api}
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2
spec:
  interfaces:
    - "${dev}"
  externalIPs: true
  loadBalancerIPs: true
EOF
}

step_mesh() {
  echo "==> Gateway API CRD ${GATEWAY_API_VERSION}"
  $KUBECTL apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  echo "==> Istio ${ISTIO_VERSION} (profile=minimal / sidecar)"
  # Gateway API リソースから gateway Deployment は Istio が自動生成するので
  # ingressgateway は要らない = minimal で足りる
  istioctl install --set profile=minimal -y --context "$KUBECTX"
  $KUBECTL -n istio-system get pods
}

step_registry() {
  local reg_ip
  reg_ip=$(node_ip "$DOCKER_VM" || true)
  if [ -z "$reg_ip" ]; then
    echo "ERROR: docker VM が user-v2 に繋がっていない。make docker-vm-net を先に実行すること。" >&2
    exit 1
  fi
  local registry="${reg_ip}:5000"

  # docker デーモンは平文 HTTP のレジストリを拒否する (localhost 以外)。
  # rootless docker の daemon.json に insecure-registries を足して再起動する。
  echo "==> docker デーモンに ${registry} を insecure registry として登録"
  limactl shell "$DOCKER_VM" -- python3 - "$registry" <<'PYEOF_GUEST'
import json, os, sys
registry = sys.argv[1]
path = os.path.expanduser("~/.config/docker/daemon.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
insecure = set(cfg.get("insecure-registries", []))
insecure.add(registry)
cfg["insecure-registries"] = sorted(insecure)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("daemon.json:", cfg)
PYEOF_GUEST
  limactl shell "$DOCKER_VM" -- systemctl --user restart docker
  # デーモンが戻るまで待つ
  for _ in $(seq 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done

  echo "==> レジストリを ${DOCKER_VM} (${registry}) に起動"
  docker rm -f registry >/dev/null 2>&1 || true
  docker run -d --restart=always --name registry -p 5000:5000 registry:2 >/dev/null

  # 各ノードの containerd に「このレジストリは平文 HTTP でいい」と教える。
  # レジストリのアドレスは docker VM の DHCP 次第で変わるので、
  # VM 作成時に焼き込まず毎回ここで書き直す。
  echo "==> 各ノードの containerd に ${registry} を登録"
  for n in $CP $WORKERS; do
    limactl shell "$n" -- sudo mkdir -p "/etc/containerd/certs.d/${registry}"
    limactl shell "$n" -- sudo tee "/etc/containerd/certs.d/${registry}/hosts.toml" >/dev/null <<EOF
server = "http://${registry}"

[host."http://${registry}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
    limactl shell "$n" -- sudo systemctl restart containerd
    # 到達できることをその場で確かめる (あとでイメージ pull に失敗してから気づくのを避ける)
    limactl shell "$n" -- curl -sS --max-time 5 "http://${registry}/v2/" >/dev/null \
      || { echo "ERROR: ${n} から ${registry} に到達できない" >&2; exit 1; }
    echo "    ${n}: OK"
  done
  echo "==> REGISTRY=${registry}"
}

# ビルド用の docker VM を用意し、クラスタと同じ user-v2 に繋ぐ。
# ここが繋がっていないとノードがレジストリからイメージを引けない。
step_docker_vm() {
  if ! limactl list -q 2>/dev/null | grep -qx "$DOCKER_VM"; then
    echo "==> docker VM を作成"
    limactl start --name "$DOCKER_VM" --network "$LIMA_NET" --cpus 4 --memory 4 \
      --tty=false template:docker
  else
    echo "==> docker VM を user-v2 に繋いで再起動"
    limactl stop "$DOCKER_VM" 2>/dev/null || true
    limactl edit "$DOCKER_VM" --set '.networks = [{"lima":"user-v2"}]'
    limactl start "$DOCKER_VM" --tty=false
  fi

  # docker CLI のプラグインはクライアント (macOS) 側で解決されるので、
  # VM の中に入っているものは使われない。ホスト側に用意する。
  # buildx は必須 (Dockerfile の --mount=type=cache は BuildKit が要る)。
  mkdir -p "$HOME/.docker/cli-plugins"
  if [ -x /opt/homebrew/opt/docker-buildx/bin/docker-buildx ]; then
    ln -sfn /opt/homebrew/opt/docker-buildx/bin/docker-buildx \
      "$HOME/.docker/cli-plugins/docker-buildx"
  else
    echo "WARN: docker-buildx が無い。brew install docker-buildx してから再実行すること。" >&2
  fi

  docker context inspect lima-docker >/dev/null 2>&1 \
    || docker context create lima-docker \
         --docker "host=unix://${HOME}/.lima/${DOCKER_VM}/sock/docker.sock" >/dev/null
  docker context use lima-docker >/dev/null
  echo "==> docker context を lima-docker にした"
}

# --- 他リポジトリ向けの接続情報 ------------------------------------------
# アプリ側のリポジトリはこの 2 つだけ知っていればクラスタに載せられる。

step_registry_addr() {
  local ip
  ip=$(node_ip "$DOCKER_VM" 2>/dev/null || true)
  [ -n "$ip" ] || { echo "docker VM が起動していない" >&2; exit 1; }
  echo "${ip}:5000"
}

step_context() { echo "$KUBECTX"; }

step_addr() {
  echo "KUBECTX=$(step_context)"
  echo "REGISTRY=$(step_registry_addr)"
}

step_status() {
  echo "=== nodes ==="; $KUBECTL get nodes -o wide
  echo; echo "=== kube-proxy が存在しないこと ==="
  $KUBECTL -n kube-system get ds 2>/dev/null | grep -i kube-proxy || echo "kube-proxy DaemonSet なし (期待通り)"
  echo; echo "=== cilium ==="; cilium status || true
  echo; echo "=== storageclass ==="; $KUBECTL get sc
  echo; echo "=== istio ==="; $KUBECTL -n istio-system get pods 2>/dev/null || true
  echo; echo "=== gateway ==="; $KUBECTL get gateway -A 2>/dev/null || true
}

# --- ディスパッチ ---------------------------------------------------------

case "${1:-}" in
  vms)        step_vms ;;
  init)       step_init ;;
  kubeconfig) step_kubeconfig ;;
  cni)        step_cni ;;
  join)       step_join ;;
  storage)    step_storage ;;
  lb)         step_lb ;;
  mesh)       step_mesh ;;
  registry)   step_registry ;;
  docker-vm)  step_docker_vm ;;
  registry-addr) step_registry_addr ;;
  context)    step_context ;;
  addr)       step_addr ;;
  status)     step_status ;;
  node-ip)    node_ip "${2:?VM 名が必要}" ;;
  *)
    echo "使い方: $0 {vms|init|kubeconfig|cni|join|storage|lb|mesh|docker-vm|registry|status|addr|registry-addr|context|node-ip <vm>}" >&2
    exit 1
    ;;
esac
