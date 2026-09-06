# local-k8s

macOS 上の Lima VM 3 台に kubeadm でクラスタを組み、Cilium (eBPF) と Istio を載せる。
**GKE に寄せた構成をローカルで再現して触るための環境**で、特定のアプリには依存しない。

```
wfd-cp   192.168.104.1   control-plane
wfd-w1   192.168.104.4   worker
wfd-w2   192.168.104.3   worker
docker   192.168.104.5   ビルド用 + レジストリ (registry.local:5000)
```

## 立てる

```bash
brew install lima kubectl cilium-cli istioctl hubble docker docker-buildx
make up          # 15〜20 分
```

`make up` が終わると接続情報が出る。

```
KUBECTX=kubeadm-local
REGISTRY=registry.local:5000
```

レジストリは**固定のホスト名**で公開する。docker VM の IP は DHCP で変わるので、
IP をイメージ名に埋めるとアプリ側のマニフェストが環境依存になりリース更新のたびに
差分が出る。`make registry` が各ノードと docker VM の `/etc/hosts` に
`registry.local` を書くので、イメージ名は常に `registry.local:5000/...` で固定できる。

## 他のリポジトリから使う

アプリ側が知る必要があるのは**この 2 つだけ**。あとは普通に build して push して apply する。

```bash
docker build -t registry.local:5000/myapp:dev .
docker push registry.local:5000/myapp:dev
kubectl --context kubeadm-local apply -k k8s/overlays/local
```

マニフェストには `registry.local:5000/myapp:dev` をそのまま書いてコミットしていい
(環境依存の値が入らない)。Makefile から引くならこう。

```make
LOCAL_K8S ?= ../local-k8s
KUBECTX    = $(shell $(MAKE) -s -C $(LOCAL_K8S) context)
REGISTRY   = $(shell $(MAKE) -s -C $(LOCAL_K8S) registry-addr)
```

実例は [what-for-dinner](../what-for-dinner) の Makefile と `k8s/` にある。

## クラスタの外から叩く

macOS から Pod や LoadBalancer IP には**直接届かない**（理由は後述）。
Service へ繋ぐには cp ノードを踏み台にしたトンネルを張る。

```bash
ssh -F ~/.lima/wfd-cp/ssh.config -N -L 18080:<LB IP>:80 lima-wfd-cp
```

## 中を見る

```bash
make status        # ノード / Cilium / Istio
make ebpf          # Service が eBPF マップにどう載っているか
make hubble-watch NS=what-for-dinner
make hubble-ui
```

## 片付け

```bash
make down          # VM を止める (クラスタの中身は残る)
make destroy       # VM ごと消す
```

---

## なぜこの構成か

| GKE | ここで組むもの | 理由 |
|---|---|---|
| control plane (不可視) | kubeadm で自分で組む | GKE が隠しているのがまさにこの層 |
| Dataplane V2 | Cilium + kube-proxy 置換 | **Dataplane V2 の中身は Cilium**。eBPF もここ |
| Cloud Load Balancing | Cilium LB IPAM + L2 広告 | MetalLB を足さずに Cilium だけで完結する |
| Cloud Service Mesh (旧 ASM) | Istio (sidecar) | **ASM の実体は Istio** |
| GKE Gateway controller | Istio の Gateway API 実装 | Ingress は機能凍結済みなので Gateway/HTTPRoute |
| PD CSI | local-path-provisioner | PVC が要るのは Postgres 1 台だけ |

## バージョン

| | | 決めた理由 |
|---|---|---|
| Kubernetes | **v1.36** | k8s の stable は v1.37 だが、**Cilium v1.20 が e2e テストしているのは 1.33〜1.36**。CNI が動かないとクラスタが成立しないので CNI 側に合わせた |
| Cilium | 1.20.1 | |
| Istio | 1.31.0 | |
| Gateway API | v1.6.2 | standard channel |

変更するときは `k8s/cluster/bootstrap.sh` の先頭の変数を書き換える。

## ネットワークの前提 (ここが一番ハマる)

`--network lima:user-v2` を付けると、Lima は**既定の slirp ユーザネットワークを
user-v2 に置き換える**。結果、各 VM の非ループバック インターフェースは
`eth0` 一本で、アドレスは 192.168.104.0/24 から配られる。

```
gateway   192.168.104.2
wfd-cp    192.168.104.1
wfd-w2    192.168.104.3
wfd-w1    192.168.104.4
```

**なぜ vzNAT ではないのか。** Lima の default.yaml に
「The "vzNAT" IP address is accessible from the host, but not from other guests」と
明記されている。ホストからは見えるが**ゲスト同士が通信できない**ので、
マルチノードクラスタが成立しない。`lima:user-v2` は VM 間通信ができて、
かつ socket_vmnet と違い root デーモンも sudo 設定も要らない。

`make vms` は最後に cp から各 worker へ ping して、ここが通ることを
確認してから終わる。**通らなければ先に進んでも無駄**なのでわざと落としている。

kubelet には `--node-ip` を明示的に渡している。インターフェースが 1 本なら
自動検出でも正しい値になるが、ノードの identity をネットワーク構成の
偶然に任せないため (インターフェースが増えた瞬間に壊れる類の依存を作らない)。

ホストからの到達は Lima のポート転送に任せる。ゲストの 6443 は自動でホストの
127.0.0.1:6443 に出るので、kubeconfig の server はそこを向ける
(だから `certSANs` に 127.0.0.1 を入れてある)。

LoadBalancer 用に確保する 192.168.104.240/28 は、DHCP が配る下位アドレスと
重ならないように上位から取っている。

## 手順

### 1. `make vms` — VM を起動する

`k8s/cluster/lima-node.yaml` から 3 台作る。テンプレートがやるのは
**kubeadm を実行できる状態までのノード準備だけ**。

- swap 無効化 (有効だと kubelet が起動を拒否する)
- `overlay` / `br_netfilter` の読み込みと `net.ipv4.ip_forward` などの sysctl
- containerd の設定で **`SystemdCgroup = true`**
  — kubelet の cgroup ドライバと食い違うと Pod が立たない定番の罠
- `pkgs.k8s.io` から kubeadm / kubelet / kubectl (`apt-mark hold` 付き)
- `bpftool` / `bpftrace` (あとで eBPF マップを直接覗くため)

最後に cp から各 worker へ ping して、user-v2 が効いていることを確認する。
**ここが通らなければ先に進んでも意味がない**ので、わざと落としている。

### 2. `make init` — kubeadm init

```
kubeadm init --config /etc/kubeadm-config.yaml --skip-phases=addon/kube-proxy
```

`--skip-phases=addon/kube-proxy` が肝。**kube-proxy を最初から入れない**。
Cilium が eBPF で Service のロードバランスを肩代わりするので、
iptables の巨大なルールチェーンごと不要になる。これが GKE Dataplane V2 の構成。

### 3. `make kubeconfig` — 手元から叩けるようにする

`/etc/kubernetes/admin.conf` を取り出し、server を 127.0.0.1:6443 に書き換えて
`~/.kube/config` に context `kubeadm-local` としてマージする。

### 4. `make cni` — Cilium

```
cilium install --version 1.20.1 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<cp の IP> --set k8sServicePort=6443 \
  ...
```

`k8sServiceHost` の指定が必須。**kube-proxy がいないので、Cilium は
`kubernetes` Service (ClusterIP) 経由で API server に到達できない**。
自分を立ち上げるために API server の実アドレスを直接知る必要がある。

その他の設定の意図:

| 設定 | 意図 |
|---|---|
| `routingMode=native` + `autoDirectNodeRoutes=true` | ノードが同一 L2 にいるのでトンネル (VXLAN) は要らない |
| `bpf.masquerade=true` | SNAT を iptables ではなく eBPF でやる |
| `hubble.*` | eBPF で拾ったフローを見るため |
| `l2announcements.enabled=true` | LoadBalancer IP を ARP で広告する。kube-proxy 置換が前提の機能 |

### 5. `make join` — worker を入れる

`kubeadm token create --print-join-command` の結果を各 worker で実行する。
その前に `/etc/default/kubelet` に `--node-ip` を書く
(kubeadm の systemd drop-in がこのファイルを読む)。

### 6. `make storage` — StorageClass

local-path-provisioner を入れて default にする。Postgres の PVC がこれを使う。

### 7. `make lb` — LoadBalancer IP

`CiliumLoadBalancerIPPool` で 192.168.104.240/28 を払い出し用に確保し、
`CiliumL2AnnouncementPolicy` で eth0 に ARP 広告させる。
MetalLB の代わりを Cilium 自身がやる。

> user-v2 はユーザモードのネットワークなので、ARP を使う L2 広告が
> 期待通り動かない可能性がある。効かない場合は Gateway の Service を
> NodePort に落とし、Lima のポート転送でホストの 127.0.0.1 から叩く。

### 8. `make mesh` — Gateway API + Istio

Gateway API の CRD (standard channel) を入れてから `istioctl install --set profile=minimal`。

`minimal` で足りるのは、**Gateway リソースから gateway の Deployment と
Service を Istio が自動生成する**ため。従来の istio-ingressgateway を
先に立てておく必要がない。

## ホストからのアクセス (実測でわかったこと)

**クラスタ内では Cilium の L2 広告は正しく動く。** cp からも worker からも
LoadBalancer IP (192.168.104.240) に到達できることを確認済み。

**しかし macOS からは直接叩けない。** 理由は 2 つあって、どちらも
user-v2 がユーザモードのネットワークであることに起因する。

1. **LB IP に経路がない。** user-v2 のホスト側は gvisor-tap-vsock の
   デーモンで、macOS に 192.168.104.0/24 のインターフェースが生えるわけではない。
2. **NodePort も自動転送されない。** Lima のポート転送は「ゲスト内で listen
   しているソケット」をゲストエージェントが検出して張る仕組みだが、
   **Cilium の NodePort は eBPF で処理されるので listen ソケットが存在しない**。
   したがって検出されず、転送ルールが作られない。

対処は cp ノードを踏み台にした SSH トンネル。

```bash
アプリ側の make k8s-tunnel        # http://127.0.0.1:18080
```

これは LB IP 宛にトンネルするので、**Cilium の LoadBalancer 経路と
Istio の Gateway を実際に通る**。`kubectl port-forward` で Pod に直接
繋ぐのと違い、経路の検証になっている。

## 既知の制約

- **local-path は node-local**。Postgres の PVC を持つノードが落ちると
  Pod は他ノードへ移れない (`postgres-0` は常に同じノードに張り付く)。
  ローカル用途では許容している。
- **hubble CLI と Cilium のバージョンがずれる**。Homebrew の hubble は 1.19.x、
  Cilium は 1.20.1 なので互換性の警告が出るが、観測自体は動く。

## 動作確認

```bash
make status

kubectl -n kube-system get ds | grep kube-proxy   # 何も出ないのが正しい
cilium status                                     # KubeProxyReplacement: True
kubectl get nodes -o wide                         # 3 台とも 192.168.104.x で Ready
```

## eBPF を覗く

```bash
# Service が eBPF マップにどう載っているか
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- bpftool map list

# フローを流し見る
make hubble-watch
make hubble-ui
```

## 壊して直す (発展課題)

```bash
# etcd のバックアップと復元
kubectl -n kube-system exec etcd-wfd-cp -- etcdctl snapshot save /tmp/snap.db ...

# 証明書
limactl shell wfd-cp -- sudo kubeadm certs check-expiration
limactl shell wfd-cp -- sudo kubeadm certs renew all

# アップグレード
limactl shell wfd-cp -- sudo kubeadm upgrade plan

# ノードの退避
kubectl drain wfd-w1 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon wfd-w1
```
