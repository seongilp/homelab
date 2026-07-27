# Kubernetes Lab — Fedora CoreOS

[prodesk](prodesk.md) 위에 **Fedora CoreOS VM으로 올린 k8s 클러스터**.
kubeadm으로 직접 구성했다. 관리형도, k3s 같은 배포판도 쓰지 않는다 —
control plane이 무엇으로 이루어지는지 보는 게 목적이라서다.

FreeBSD 랩이 커널을 보는 자리라면, 여기는 **불변 OS 위에서 컨테이너 오케스트레이션이
어떻게 설치되는가**를 보는 자리다.

## 구성

**control plane 3대 HA.** etcd가 과반으로 동작하므로 3대여야 1대 장애를 견딘다.
2대는 오히려 더 나쁘다 — 1대만 죽어도 과반이 깨진다.

| 노드 | 역할 | IP | 스펙 |
|------|------|-----|------|
| `fcos-cp1` | control-plane | 192.168.122.50 | 4 vCPU / 8G / 60G |
| `fcos-cp2` | control-plane | 192.168.122.52 | 4 vCPU / 8G / 60G |
| `fcos-cp3` | control-plane | 192.168.122.53 | 4 vCPU / 8G / 60G |
| `fcos-w1` | worker | 192.168.122.51 | 4 vCPU / 8G / 60G |
| `fcos-w2` | worker | 192.168.122.54 | 4 vCPU / 4G / 60G |
| **VIP** | kube-vip | **192.168.122.49** | API 엔드포인트 |

```
OS        Fedora CoreOS 44.20260707.3.1 (stable)
k8s       v1.36.3   (kubeadm · kubelet · kubectl)
런타임    CRI-O 1.36.2
CNI       Flannel   pod 10.244.0.0/16 · svc 10.96.0.0/12
HA        kube-vip v1.2.1 (ARP/L2, leader election)
애드온    metrics-server · VictoriaMetrics · local-path-provisioner
네트워크  libvirt default NAT, DHCP 예약으로 IP 고정
```

VIP `.49`도 **DHCP 예약으로 잡아뒀다** — libvirt의 DHCP 범위가 `.2~.254`라
그냥 두면 다른 VM에 그 주소가 나갈 수 있다. 더미 MAC으로 예약해 막았다.

## HA — 엔드포인트가 먼저다

`kubeadm init`을 `--control-plane-endpoint` 없이 하면 **나중에 cp를 못 늘린다.**

```
unable to add a new control plane instance to a cluster that
doesn't have a stable controlPlaneEndpoint address
```

당연한 제약이다. cp가 여러 대면 워커와 kubectl이 **어느 주소로 API를 찾을지**가
정해져 있어야 한다. 이 랩도 처음엔 단일 cp로 세웠다가 이 벽에 막혀 재구축했다.
**HA로 갈 생각이 조금이라도 있으면 처음부터 endpoint를 박아야 한다.**

앞단은 kube-vip을 골랐다. cp 노드에 static pod로 떠서 리더가 VIP를 ARP로
가져가는 방식이라 **별도 로드밸런서 VM이 필요 없다.** prodesk에 HAProxy를 두는
방법도 있지만, 그러면 하이퍼바이저가 단일 실패점이 된다.

```
prodesk:6443 ──DNAT──> VIP 192.168.122.49 ──(리더)──> cp1 | cp2 | cp3
```

## 왜 CoreOS인가

**패키지를 설치하는 OS가 아니다.** 루트가 읽기 전용이고, 설정은 첫 부팅 때 Ignition이
한 번 적용하고 끝난다. 바꾸려면 노드를 갈아끼운다. k8s 노드처럼 **똑같은 것을 여러 대
찍어내고 통째로 교체하는** 대상과 성격이 맞는다.

설정은 Butane(YAML)으로 쓰고 Ignition(JSON)으로 컴파일한다. Ignition을 직접 쓰면
파일 내용까지 data URL로 인코딩해야 해서 사람이 다룰 물건이 아니다.

```
butane/node.bu.tmpl  ──(hostname 치환)──> *.bu ──(butane)──> *.ign ──(qemu fw_cfg)──> VM 첫 부팅
```

노드마다 다른 것은 hostname뿐이라 **템플릿 하나를 공유**한다. 파일을 복제하면
설정이 갈라진다.

## 겪은 것

### 1. AppArmor가 Ignition 파일을 막았다

Ubuntu 호스트에서 qemu에 `-fw_cfg ...,file=/data/vms/fcos-cp1.ign`을 넘겼더니
VM이 뜨자마자 죽었다.

```
qemu-system-x86_64: can't load /data/vms/fcos-cp1.ign: Permission denied
```

파일 권한은 `0644`에 소유자도 `libvirt-qemu`였다. libvirt가 VM마다 생성하는 AppArmor
프로파일이 **디스크 경로만 허용**하고 그 외 파일은 막기 때문이다. 예외를 한 줄 추가했다.

```bash
# /etc/apparmor.d/local/abstractions/libvirt-qemu
/data/vms/*.ign r,
```

### 2. CRI-O rpm 저장소가 사라져 있었다

`pkgs.k8s.io`의 CRI-O 저장소가 **403**, OBS 원본은 **404**였다. k8s 본체(`core:`)는
멀쩡한데 애드온만 죽어 있다.

Fedora 44 기본 저장소에도 cri-o가 있지만 **1.32**다. k8s 1.36과 네 마이너 차이라
쓸 물건이 아니다. CRI-O는 k8s와 마이너 버전을 맞춰 내는 프로젝트다.

→ 공식 **static bundle**(`storage.googleapis.com/cri-o/artifacts/`)로 설치했다.
버전은 맞췄지만 **rpm-ostree 레이어 밖**에 놓이는 대가를 치른다. OS를 롤백해도
CRI-O는 따라 돌아가지 않는다.

### 3. 읽기 전용 `/usr`와 싸우기

CRI-O install 스크립트는 `/usr/libexec/crio`에 바이너리를 깔려고 한다. CoreOS에서는
불가능하다.

```bash
PREFIX=/usr/local LIBEXECDIR=/usr/local/libexec ./install
```

CoreOS의 `/usr/local`은 `/var/usrlocal` 심볼릭 링크라 쓸 수 있다. install 스크립트가
`10-crio.conf`의 런타임 경로까지 같이 치환해준다.

> 이 스크립트는 상대 경로(`cni-plugins/*`)를 참조해서 **번들 디렉터리 안에서
> 실행해야 한다.** 밖에서 부르면 CNI 플러그인 설치 단계에서 조용히 실패한다.

### 4. `kubelet.service`가 없다

`rpm-ostree install kubelet` 직후 `systemctl enable kubelet`이 "unit does not exist"로
실패한다. **레이어링은 재부팅해야 반영된다.** 설치와 활성화 사이에 재부팅이 들어가야
한다는 게 이 OS의 리듬이다.

### 5. kube-vip이 첫 노드에만 있었다 — HA가 아니었던 HA

3대를 붙이고 `virsh destroy`로 VIP 리더(cp1)를 죽였다. **3분이 지나도 복구되지
않았다.**

```
21:33:04  Unable to connect to the server
21:33:13  Unable to connect to the server
...
21:36:13  Unable to connect to the server     ← 계속
```

`kubeadm join --control-plane`은 **kubeadm이 만드는 static pod만 생성한다** —
etcd·apiserver·controller-manager·scheduler 넷. 직접 넣은 `kube-vip.yaml`은
복제 대상이 아니다.

```
cp1: etcd apiserver controller-manager scheduler kube-vip
cp2: etcd apiserver controller-manager scheduler          ← 없음
cp3: etcd apiserver controller-manager scheduler          ← 없음
```

VIP를 이어받을 노드가 애초에 없었다. **etcd는 3중화됐는데 진입점은 1중화**인
상태였고, 노드 목록만 보면 멀쩡한 HA처럼 보인다.

세 노드 모두에 manifest를 깔고 다시 죽였다.

```
21:38:28 (+0s)   ...
21:38:47 (+19s)  ok    ← cp3가 VIP 인수
```

**19초.** cp1이 죽은 채로 `kubectl scale`도 정상 동작했고, 복귀 후 etcd 3멤버가
같은 raft index로 맞았다.

> 죽여보지 않았으면 몰랐다. HA 구성은 **장애를 실제로 만들어봐야** 검증된다.
> 노드가 Ready로 보이는 것과 장애를 견디는 것은 다른 문제다.

### 6. metrics-server가 kubelet 인증서를 거부했다

`k9s`에서 CPU/MEM이 계속 `n/a`였다.

```
Failed to scrape node: x509: cannot validate certificate for
192.168.122.52 because it doesn't contain any IP SANs
```

kubelet의 serving 인증서가 self-signed이고 IP SAN이 없다. 정석은 kubelet
serving cert rotation(`serverTLSBootstrap: true`)을 켜고 CSR을 승인하는 것이지만,
**노드를 추가할 때마다 CSR 승인이 따라붙는다.** 테스트 랩이라
`--kubelet-insecure-tls`로 넘어갔다. 부채 목록에 올린 항목.

### 7. SELinux는 permissive로 뒀다

CRI-O를 비표준 경로에 두는 구성이라 라벨링 문제를 피했다. **테스트 클러스터라서
내린 결정**이고, enforcing으로 되돌리려면 `/usr/local/libexec/crio`와 `/opt/cni/bin`의
컨텍스트를 직접 검증해야 한다. 부채로 남겨둔 항목.

## 맥북에서 붙기

API 서버가 libvirt NAT 안에 있어 밖에서 안 보인다. prodesk에 DNAT를 걸어 통과시킨다.

```
mac ──k9s──> prodesk:6443 ──DNAT──> VIP 192.168.122.49 ──> 리더 cp
```

- apiserver 인증서 SAN에 prodesk의 LAN/Tailscale IP를 넣고 재발급 (`kubeadm-config`
  ConfigMap에도 반영해야 갱신 때 유지된다)
- `k8s-api-forward.service` — iptables DNAT + FORWARD + MASQUERADE, 재부팅 후 자동 적용
- kubeconfig는 `fcos-prodesk` 컨텍스트로 병합

**API 서버 포트가 LAN에 열려 있다.** 인증은 유지되지만 노출은 노출이다. SSH 터널
대신 택한 편의고, 닫으려면 `systemctl disable --now k8s-api-forward`.

> prodesk의 LAN IP가 바뀌면 **인증서 SAN · DNAT 규칙 · kubeconfig 세 곳**이 동시에
> 깨진다. 실제로 `.116 → .111` 변경 때 겪었다. IP를 세 군데에 박아둔 구조라
> 어느 하나만 고치면 조용히 안 된다.

인증서 SAN은 **cp 3대 모두** 갱신해야 한다. VIP 리더가 어느 노드로든 넘어갈 수
있으므로, 한 대만 고치면 페일오버 후에 TLS 검증이 깨진다. `kubeadm join` 시점의
인증서에는 VIP와 자기 IP만 들어 있다.

## 자동 업데이트를 껐다

Zincati(CoreOS 자동 업데이트)를 mask했다. **클러스터가 도는 중에 노드가 알아서
재부팅하면 안 된다.** OS를 올릴 때는 `rpm-ostree upgrade`를 수동으로,
노드를 하나씩 드레인하면서 한다.

불변 OS의 자동 업데이트는 단일 노드에는 축복이지만 **클러스터에는 조율이 필요한
일**이다. 끄는 게 아니라 나중에 제대로 붙일 항목(kured 같은 재부팅 조율자)에 가깝다.

## 백업 관점의 예외

FCOS VM 5대는 **qcow2**다. prodesk의 다른 VM은 전부 raw인데([prodesk.md](prodesk.md)),
FCOS 배포 이미지가 qcow2라 그대로 썼다.

`data/vms` 데이터셋 안에 있으므로 **msg10p로의 zfs send 백업에는 포함된다.**
포맷만 다르다.

## 모니터링 — VictoriaMetrics

클러스터 안은 [victoria-metrics-k8s-stack](https://github.com/VictoriaMetrics/helm-charts)으로
본다. 홈랩 전체 감시(Beszel)와는 층이 다르다 — [monitoring.md](monitoring.md) 참고.

```
VMSingle      메트릭 저장 (retention 30d, 20Gi)
VMAgent       스크랩 → VMSingle
VMAlert       룰 평가 → Alertmanager
Grafana       대시보드 41개 자동 프로비저닝
node-exporter · kube-state-metrics
```

**vmcluster가 아니라 VMSingle이다.** 노드 5대 규모에서 vminsert/vmselect/vmstorage를
나눌 이유가 없다. 쪼개는 순간 운영 대상이 셋으로 늘어난다.

```
스크랩 타겟   37개 (전부 up)
메트릭 종류   2,182
수집 속도     ~5,300 rows/s
```

### StorageClass가 먼저 필요했다

PVC를 쓰는 첫 워크로드라 **StorageClass가 아예 없다는 걸 여기서 알았다.** kubeadm은
스토리지 프로비저너를 깔아주지 않는다. VMSingle의 PVC가 Pending에 걸린다.

local-path-provisioner(Rancher)를 default StorageClass로 깔았다. 노드 로컬 디스크를
쓰므로 **파드가 다른 노드로 옮기면 데이터에 접근할 수 없다.** 테스트 랩이라 수용한
제약이고, 실사용이라면 NFS(msg10p) 백엔드나 CSI가 필요하다.

### 스크랩을 일부러 끈 것들

`kubeControllerManager` · `kubeScheduler` · `kubeEtcd` · `kubeProxy`를 비활성화했다.

kubeadm 기본 구성에서 **controller-manager와 scheduler는 `127.0.0.1`에만 바인딩**하고,
etcd는 클라이언트 인증서를 요구한다. 그대로 켜두면 타겟이 계속 down으로 잡혀
**알림 노이즈만 만든다.** 감시가 늘 빨간불이면 빨간불을 무시하게 된다.

끈 게 아니라 **노출 설정을 손볼 때까지 미뤄둔 것**이고, values 파일에 이유를 적어뒀다.

### 외부 노출은 VIP로

NodePort는 모든 노드에서 열리지만, prodesk DNAT를 **특정 노드로 보내면 그 노드가
죽을 때 경로가 끊긴다.** kube-vip VIP로 보내 리더를 따라가게 했다.

```
mac ──> prodesk:30300 ──DNAT──> VIP .49:30300 ──> Grafana
        prodesk:30428                    :30428 ──> VMUI
```

`k8s-nodeport-forward.service`로 재부팅 후에도 유지된다. API 서버용
`k8s-api-forward.service`와 같은 구조다.

### 자기 자신을 감시하는 문제

이 스택은 **클러스터 안에 있다.** 클러스터가 죽으면 그걸 알려줄 감시도 같이 죽는다.
[monitoring.md](monitoring.md)의 "감시자는 감시 대상 밖에 둔다" 원칙과 정면으로
어긋난다.

지금은 **밖에서 보는 층이 따로 있어서** 버티는 구조다 — Beszel 에이전트가 prodesk를
호스트 레벨에서 보고 있고, 그 허브는 ebs에 있다. VM이 통째로 죽는 상황은 그쪽에서
잡힌다. VictoriaMetrics는 **클러스터가 살아 있을 때 그 안을 들여다보는 용도**로
역할을 한정한다.

제대로 하려면 Alertmanager를 텔레그램에 물리고, 그와 별개로 **밖에서 클러스터
엔드포인트를 찔러보는 감시**가 있어야 한다. 아직 없다.

## 자원

노드 5대를 올린 뒤 prodesk 상태. 클러스터는 생각보다 가볍다.

```
fcos-cp1   172m (4%)   1387Mi (17%)
fcos-cp2   178m (4%)   1067Mi (13%)
fcos-cp3   183m (4%)   1040Mi (13%)
fcos-w1     42m (1%)    647Mi ( 8%)
fcos-w2     67m (1%)    640Mi (16%)
```

prodesk 전체로는 **VM 할당 62G / 물리 61G**로 오버커밋 상태지만
실사용은 그 절반이고 PSI는 0이다. w2를 4G로 준 이유이기도 하다 —
할당 합계가 물리를 넘기 시작하면 여유분을 실사용 기준으로 봐야 한다.
([prodesk.md](prodesk.md)의 메모리 절)

## 다음

- [ ] control-plane taint 되살리기 (워커가 2대이므로 cp는 시스템 파드용으로 비우기)
- [ ] SELinux enforcing 복귀
- [ ] kubelet serving cert rotation + CSR 자동 승인 (metrics-server 정석 해법)
- [ ] Alertmanager → 텔레그램 (홈랩 단일 채널에 합류)
- [ ] 클러스터 밖에서 엔드포인트를 감시하는 층
- [ ] Ingress + cert-manager
- [ ] etcd 백업을 msg10p 백업 흐름에 연결
- [ ] 노드 재부팅 조율자(kured) — Zincati를 다시 켜려면 필요
