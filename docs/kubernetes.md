# Kubernetes Lab — Fedora CoreOS

[prodesk](prodesk.md) 위에 **Fedora CoreOS VM으로 올린 k8s 테스트 클러스터**.
kubeadm으로 직접 구성했다. 관리형도, k3s 같은 배포판도 쓰지 않는다 —
control plane이 무엇으로 이루어지는지 보는 게 목적이라서다.

FreeBSD 랩이 커널을 보는 자리라면, 여기는 **불변 OS 위에서 컨테이너 오케스트레이션이
어떻게 설치되는가**를 보는 자리다.

## 구성

| 노드 | 역할 | IP | 스펙 |
|------|------|-----|------|
| `fcos-cp1` | control-plane | 192.168.122.50 | 4 vCPU / 8G / 60G |
| `fcos-w1` | worker | 192.168.122.51 | 4 vCPU / 8G / 60G |

```
OS        Fedora CoreOS 44.20260707.3.1 (stable)
k8s       v1.36.3   (kubeadm · kubelet · kubectl)
런타임    CRI-O 1.36.2
CNI       Flannel   pod 10.244.0.0/16 · svc 10.96.0.0/12
네트워크  libvirt default NAT, DHCP 예약으로 IP 고정
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

### 5. SELinux는 permissive로 뒀다

CRI-O를 비표준 경로에 두는 구성이라 라벨링 문제를 피했다. **테스트 클러스터라서
내린 결정**이고, enforcing으로 되돌리려면 `/usr/local/libexec/crio`와 `/opt/cni/bin`의
컨텍스트를 직접 검증해야 한다. 부채로 남겨둔 항목.

## 맥북에서 붙기

API 서버가 libvirt NAT 안에 있어 밖에서 안 보인다. prodesk에 DNAT를 걸어 통과시킨다.

```
mac ──k9s──> prodesk:6443 ──DNAT──> 192.168.122.50:6443
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

## 자동 업데이트를 껐다

Zincati(CoreOS 자동 업데이트)를 mask했다. **클러스터가 도는 중에 노드가 알아서
재부팅하면 안 된다.** OS를 올릴 때는 `rpm-ostree upgrade`를 수동으로,
노드를 하나씩 드레인하면서 한다.

불변 OS의 자동 업데이트는 단일 노드에는 축복이지만 **클러스터에는 조율이 필요한
일**이다. 끄는 게 아니라 나중에 제대로 붙일 항목(kured 같은 재부팅 조율자)에 가깝다.

## 백업 관점의 예외

FCOS VM 2대는 **qcow2**다. prodesk의 다른 VM은 전부 raw인데([prodesk.md](prodesk.md)),
FCOS 배포 이미지가 qcow2라 그대로 썼다.

`data/vms` 데이터셋 안에 있으므로 **msg10p로의 zfs send 백업에는 포함된다.**
포맷만 다르다.

## 다음

- [ ] control-plane taint 되살리기 (워커가 생겼으니 시스템 파드용으로 비워두기)
- [ ] SELinux enforcing 복귀
- [ ] 워커 1대 더 — 진짜 스케줄링 분산 보기
- [ ] Ingress + cert-manager
- [ ] etcd 백업을 msg10p 백업 흐름에 연결
