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
  NET   USB 2.5G (주) + Wi-Fi (폴백) → [network.md](network.md)
```

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

**전부 `data/vms` 아래 raw 포맷**이다. qcow2를 쓰지 않는 이유와 이전 과정은
[backup.md](backup.md)에 정리했다.

> `zen`은 원래 `/var/lib/libvirt/images/`(ext4 루트)에 qcow2로 있었다.
> 데이터셋 밖이라 **백업에서 조용히 누락돼 있었다.** VM 하나가 다른 파일시스템에 있으면
> 이런 일이 생긴다.

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
export도 `192.168.123.116`(prodesk) 한정으로 제한한다.

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
