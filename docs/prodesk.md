# prodesk — 컴퓨트 / 미디어 노드

랩 서버 겸 셀프호스트 서비스 노드. **VM으로 학습 환경을, 컨테이너로 미디어 서비스를** 돌린다.
스토리지는 자체적으로 거의 갖지 않고 [msg10p](storage.md)의 ZFS를 NFS로 빌려 쓴다.

## 하드웨어

```
HP EliteDesk 800 G6 Desktop Mini
  CPU   Intel i9-10900 (10c/20t, 2.8GHz) + UHD Graphics 630 (QSV)
  RAM   64GB
  SSD   Crucial MX500 1TB (SATA)  — Ubuntu 26.04 루트
  NVMe  WD Black SN750 500GB      — ZFS `data` 풀
  NET   USB 2.5G Realtek RTL8156 (주, .111) + Wi-Fi (폴백, .109) → [network.md](network.md)
```

> 랜카드는 2026-07-27에 갈았다. 이전 iptime 어댑터가 **3일간 686번 USB 재열거**를 일으켜
> cloudflared 끊김과 Beszel 헛알림의 원인이 되고 있었다. 증상이 조용해서 찾는 데
> 오래 걸렸다 — [network.md](network.md#usb-랜카드가-조용히-죽는-법) 참고.

**미니 PC라 드라이브 베이가 없다.** 그래서 대용량 데이터는 전부 msg10p에 두고 NFS로 붙인다.
이 제약이 아래 모든 설계 결정의 출발점이다.

## ZFS `data` 풀 — 워크로드별 recordsize

```
data  464G (17% 사용)  — 단일 vdev (WD SN750 500GB)
```

**미러가 없다.** ZFS 체크섬으로 손상을 감지는 하지만 복구할 사본이 없어,
msg10p로의 복제가 유일한 방어선이다.

| 데이터셋 | 용량 | recordsize | 용도 |
|----------|------|-----------|------|
| `data/vms` | 59.4G | **64K** | VM 이미지 3대 (랜덤 I/O) |
| `data/immich-lib` | 16.8G | **1M** | 썸네일·인코딩 (순차, 재생성 가능) |
| `data/immich-db` | 938M | **8K** | PostgreSQL 페이지 크기에 맞춤 |
| `data/litestream` | 919M | 128K | SQLite WAL 연속 복제본 |
| `data/db-dumps` | 498M | 128K | 일일 DB 덤프 (zstd) |
| `data/jellyfin` · `data/pinchflat` | 262M | 128K | SQLite |

recordsize를 워크로드에 맞추는 게 요점이다. Postgres에 128K를 주면 8K 페이지 하나 고치려고
128K를 읽고 쓰는 낭비가 생긴다.

## VM (libvirt/KVM)

| VM | vCPU/RAM | 용도 |
|----|----------|------|
| `freebsd-dev` | 8 / 12G | FreeBSD 16.0-CURRENT — 커널 학습 ([freebsd.md](freebsd.md)) |
| `freebsd` | 8 / 12G | FreeBSD 15.1-RELEASE — jail·pkgbase 실습 |
| `zen` | 2 / 2G | 실험용 |
| `fcos-cp1` | 4 / 8G | Fedora CoreOS — k8s control plane ([kubernetes.md](kubernetes.md)) |
| `fcos-w1` | 4 / 8G | Fedora CoreOS — k8s worker |

**전부 `data/vms` 아래**에 둔다. FreeBSD·zen은 raw 포맷이다.
이들을 qcow2에서 raw로 옮긴 이유와 과정은 [backup.md](backup.md)에 정리했다.

> `zen`은 원래 `/var/lib/libvirt/images/`(ext4 루트)에 qcow2로 있었다.
> 데이터셋 밖이라 **백업에서 조용히 누락돼 있었다.** VM 하나가 다른 파일시스템에 있으면
> 이런 일이 생긴다.

> FCOS 2대는 **qcow2**다 — 배포 이미지가 qcow2라 그대로 썼다. 포맷은 다르지만
> `data/vms` 안에 있어 zfs send 백업에는 포함된다. 위 `zen` 건과 달리 조용한 누락은 아니다.

## 서비스 (Docker)

| 서비스 | 포트 | DB | 미디어 |
|--------|------|-----|--------|
| **Immich** | 9000 | PostgreSQL (로컬) | `zpool/photos` NFS — External Library |
| **Pinchflat** | 9001 | SQLite (로컬) | `zpool/youtube` NFS |
| **Jellyfin** | 9002 | SQLite (로컬) | `zpool/youtube` · `zpool/ds920p` NFS **ro** |

compose는 `/opt/<서비스>/docker-compose.yml`.

### 공통 원칙: DB는 로컬, 미디어는 NFS

PostgreSQL·SQLite 모두 **NFS의 파일 락 의미가 자신이 기대하는 POSIX 락과 달라**,
정전이나 네트워크 끊김에서 복구 불가능한 손상이 난다. 그래서 DB는 예외 없이 로컬 ZFS에 둔다.

미디어만 NFS로 붙이고, 읽기만 하는 쪽(Jellyfin)은 `:ro`로 건다 —
실수로 라이브러리를 지우는 경로를 만들지 않는다.

### Immich External Library

원본을 `zpool/photos`에 둔 채 **스캔·인덱싱만** 한다. Immich가 원본을 옮기거나
이름을 바꾸지 않으므로, msg10p의 사진 아카이브 구조가 그대로 보존된다.
썸네일·미리보기만 로컬(`data/immich-lib`)에 쌓인다.

제외 규칙에 `**/._*`와 `**/@eaDir/**`를 넣는다. macOS AppleDouble과 시놀로지 썸네일이
자산으로 잡히면 개수가 두 배로 부푼다.

### 하드웨어 트랜스코딩

UHD 630이 있어 `/dev/dri/renderD128`을 컨테이너에 넘기고 `render`(GID 992) 그룹을 추가한다.
Jellyfin 설정 → 재생 → 하드웨어 가속에서 **Intel QuickSync**를 켜야 실제로 쓰인다.

## NFS 마운트

```
192.168.123.100:/zpool/photos   → /mnt/nas/photos    (rw)
192.168.123.100:/zpool/youtube  → /mnt/nas/youtube   (rw)
192.168.123.100:/zpool/ds920p   → /mnt/nas/ds920p    (rw, 컨테이너엔 ro)
```

`/etc/fstab`에 `_netdev,x-systemd.automount`로 등록.

**`/zpool` 전체를 붙이지 않고 필요한 데이터셋만 개별 export**했다. 전체를 rw로 걸면
prodesk에서 msg10p의 백업 데이터(`zpool/backup`)까지 지울 수 있는 경로가 생긴다.
export도 `192.168.123.111`(prodesk) 한정으로 제한한다.

## 백업

자기 데이터를 msg10p로 밀어 넣는다. 상세는 [backup.md](backup.md).

```
매일 04:00  db-backup.sh   서비스 DB 덤프 + Litestream 복제본 → zpool/backup/prodesk-{db,litestream}
매일 04:30  vm-backup.sh   data/vms → zpool/backup/prodesk-vms  (ZFS 증분, 3초)
상시        litestream     SQLite WAL 연속 복제 (RPO 10초)
```

목적지가 `zpool/backup` 아래라 **msg10p의 일일 ZFS 스냅샷 30일 보호**를 자동으로 받는다.

> **문서에 "복구는 백업 의존"이라 써두고 정작 백업이 없었다.** 2026-07-26에야 걸었다.
> 설계 문서에 적어둔 전제를 실제로 구현했는지는 별개 문제다.

또한 ebs의 백업을 받는 **수신처** 역할도 한다 (`~/backups/ebs`, msg10p와 이중 목적지).

## 하드웨어 이상징후 보고

```
매일 07:20  hw-report.sh  ──ssh──▶  msg10p:/zpool/backup/prodesk-hw/status.txt
매일 07:30  msg10p 의 backup-healthcheck.sh 가 읽어 텔레그램으로 통보
```

**밀어넣는 방향으로 만들었다.** msg10p→prodesk SSH를 새로 뚫으면 모든 백업의 종착지가
다른 서버에 들어갈 수 있게 된다. 백업이 이미 prodesk→msg10p 방향이라 신뢰 관계가 늘지 않는다.

감시 대상은 **누적이 아니라 24시간 증가분**이다. 누적은 늘기만 해서 악화 여부를 못 알려준다.

| 항목 | 경보 조건 | 왜 보는가 |
|------|-----------|-----------|
| USB 재열거 | >5회/일 | 랜카드가 조용히 죽는 걸 잡는다 |
| NVMe AER Correctable | >2,000건/일 | 평시 ~960건. 급증이 링크 열화 신호 |
| AER fatal · nonfatal | >0 | 복구 못 한 에러 = 실제 손상 |
| NVMe 미디어 오류 | >0 | 디스크 자체 손상 |
| ZFS `data` 체크섬 | >0 | 단일 vdev라 복구 수단이 없다 |
| 보고 신선도 | >26시간 | **값이 안 오는 것 자체가 신호**다 |

마지막 항목이 중요하다. prodesk가 죽거나 주소가 바뀌어 조용히 단절되는 경우를 잡아준다.

### NVMe PCIe AER — 시끄럽지만 무해한 것

`data` 풀의 SN750이 시간당 40건씩 Correctable 에러를 낸다.

```
PCIe Bus Error: severity=Correctable, type=Physical Layer, (Receiver ID)
  [ 0] RxErr (First)

RxErr 2612 · BadTLP 0 · BadDLLP 0 · fatal 0 · nonfatal 0
```

**RxErr만 있고 BadTLP·BadDLLP가 0인 게 진단의 핵심이다.** BadTLP/BadDLLP는 PHY를 통과한 뒤
CRC에서 깨진 패킷이다. 그게 0이면 **깨진 데이터가 물리 계층 위로 올라온 적이 없다**는 뜻이고,
링크 계층 재전송으로 전부 메워졌다는 얘기다. ZFS 체크섬 0·SMART 미디어 오류 0이 이를 뒷받침한다.

이 조합은 **ASPM L1.2 복귀 서명**으로 본다. 저전력 상태에서 깨어날 때 수신부가 비트 락을
다시 잡는 구간에서 쓰레기 심볼이 잡히는 것. 접촉 불량이었다면 부하에 몰리고
BadTLP가 같이 오르며 링크 폭이 강등되는데, 셋 다 아니다(8GT/s x4 유지).

확정하려면 `pcie_aspm.policy=performance`로 L1을 끄고 관찰하면 된다. 다만 지금은
실익이 로그가 조용해지는 정도라 **감시만 걸고 두는 쪽**을 택했다.


## 메모리 — VM 5대 + 컨테이너 6종

k8s 랩([kubernetes.md](kubernetes.md))으로 VM 2대가 늘었을 때의 스냅샷.

```
물리 61G          used 33G · available 28G · swap 5.5G/8G
VM 할당 합계      42.9G   (freebsd 12G ×2 · fcos 8G ×2 · zen 2G)
VM 실제 RSS       26.5G   (freebsd 9.3+9.0 · fcos 3.7+2.8 · zen 1.7)
Docker            9.2G    (immich_server 5.5 · jellyfin 2.7 · 나머지 1G)
ZFS ARC           2.6G
```

**swap 5.5G를 압박으로 오해하기 쉽다.** 판단 근거는 PSI다.

```
/proc/pressure/memory
some avg10=0.04  full avg10=0.04     ← 사실상 0
```

`swappiness=60`(기본값)이 **유휴 페이지를 미리 밀어낸 결과**지, 메모리가 모자라 쫓아낸 게
아니다. swap 상위 3개가 전부 qemu인데 오래 idle한 FreeBSD VM 페이지들이다.

`free`의 swap 사용량이나 `vmstat`의 순간 `so` 값만 보면 잘못 읽는다.
**메모리가 실제로 부족한지는 PSI로 본다.**

> 할당(42.9G)과 실사용(26.5G)의 차이도 크다. VM은 게스트가 실제로 만진 페이지만
> 호스트 RSS에 잡히므로, 갓 부팅한 FCOS처럼 할당 8G에 실사용 3G대인 경우가 흔하다.
> **할당 합계로 용량을 계산하면 실제보다 훨씬 빡빡하게 나온다.**

## 자원 경합 — 겪은 것

Immich 초기 인덱싱(사진 62,240장)이 돌 때 다른 서비스가 눈에 띄게 느려졌다.

```
load average             18.14 / 20코어   ← 포화
immich_machine_learning  810%             ← 얼굴인식·CLIP
immich_server            212%
jellyfin                 146%             ← 라이브러리 스캔
```

처음엔 디스크 I/O를 의심했지만 **msg10p 디스크는 `%util` 30%로 여유로웠다.**
병목은 prodesk의 CPU였다. ML 작업이 8코어를 통째로 물어 Jellyfin이 CPU를 못 받은 것.

- 초기 인덱싱은 일회성이므로 대개 **기다리는 게 답**이다
- 급하면 Immich 관리 → 작업에서 얼굴 인식·스마트 검색 **동시 실행 수를 낮춘다**
- 여러 서비스의 초기 스캔을 **동시에 시작하지 않는다** (Jellyfin 라이브러리 스캔이 겹쳐 악화됐다)

부하를 볼 때는 `docker stats`로 컨테이너별 CPU를, 원격 스토리지는 `iostat -x`의 `%util`을
같이 봐야 어느 쪽이 병목인지 갈린다.
