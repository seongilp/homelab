# Storage (ZFS)

## 풀 레이아웃

### msg10p — 두 미러 풀 (장애 격리)

```
zpool   9.09T  (75% 사용)   — 주 데이터 / NAS 백업 / 사진 아카이브
└─ mirror-0
   ├─ HGST HUH721010ALE604  (10TB, CMR)
   └─ HGST HUH721010ALE604  (10TB, CMR)

zpool2  3.62T  (49% 사용)   — 부 데이터 (외장드라이브 아카이브)
└─ mirror-0
   ├─ WD Red Plus WD40EFZX  (4TB, CMR)
   └─ WD Red Plus WD40EFZX  (4TB, CMR)

nvme0n1 (SK hynix 1TB)      — OS(root) 전용, 풀 미포함
```

두 풀을 **일부러 분리**했다. 오래된 중고 디스크(zpool2)가 죽어도 주 백업 풀(zpool)은 무사하도록.

**주요 데이터셋**

| 데이터셋 | 용량 | recordsize | 압축 | 용도 |
|----------|------|-----------|------|------|
| `zpool/rsync` | 5.34T | 128K | lz4 | NAS 백업 미러 |
| `zpool/macbook` | 463G | 128K | zstd | Mac restic/kopia 리포 |
| `zpool/photos` | 283G | **1M** | on | 사진 원본 아카이브 |
| `zpool/backup` | 442G | 128K | lz4 | 각종 백업 |
| `zpool2/mac_backup` | 1.12T | 128K | lz4 | 외장드라이브 미러 |
| `zpool2/orico` | 686G | 128K | lz4 | 외장드라이브 미러 |

### prodesk — NVMe 단일 풀

```
data  464G  (9% 사용)  — 컴퓨트 작업 공간 / VM
└─ nvme (WD Black SN750 500GB)   ※ 단일 vdev — 체크섬 감지만, 복구는 백업 의존
sda   (Crucial MX500 1TB, SATA)  — Ubuntu 시스템
```

단일 디스크 풀이라 자가 복구(미러)는 없지만 체크섬으로 손상은 감지된다.
중요 데이터는 msg10p로 백업. (원래 Windows 듀얼부트였으나 밀고 ZFS로 전환)

## 디스크 검증이 먼저

새(중고) 디스크는 풀에 넣기 전에 반드시 검증한다.

- `smartctl -t long` — 표면 전체를 섹터 단위로 읽어 숨은 불량 섹터를 드러냄
- 실제로 한 디스크는 SMART 단기 테스트에서 **read failure**로 불량 판정 → 폐기
- ZFS 월간 스크럽(cron)으로 저장 후 bit rot 감시 — 체크섬으로 손상 자동 감지

## SMR 금지

WD Blue 같은 SMR(기와식 기록) 디스크는 ZFS에 넣지 않는다.
순차 쓰기는 정상이지만 리실버 같은 랜덤 쓰기에서 속도가 수 MB/s로 폭락,
ZFS가 "고장난 디스크"로 오판해 풀에서 쫓아내는 사고가 난다 (2020 WD Red SMR 사태).

## 튜닝 — 측정 후에만

| 항목 | 값 | 근거 |
|------|-----|------|
| `zfs_arc_max` | RAM의 ~77% | 스토리지 전용 박스 (다른 RAM 수요 없음) |
| `recordsize` (사진) | 1M | 큰 순차 파일 위주 |
| `recordsize` (VM zvol) | 64K | 랜덤 I/O |
| `atime` | off | 불필요한 메타데이터 쓰기 제거 |

**하지 않은 것**: L2ARC. ARC 적중률이 99.8%라 램에서 거의 다 처리 → 캐시 추가 이득 없음.
special vdev도 보류 (메타데이터 원본을 옮기는 것이라 NVMe **미러 필수** — 단일 장치면 풀 전체가 죽는다).

## special vdev vs L2ARC

| | L2ARC (캐시) | special vdev (본체) |
|---|---|---|
| 저장 내용 | 사본 | **원본** (메타데이터) |
| 1개로 붙이면 | 안전 | **풀 전체 사망 위험** |
| 필요 개수 | 1개 | **미러 2개 이상 필수** |

## 파일 공유: NFS

SMB에서 NFS로 전환. 대용량 전송은 동률이지만 **메타데이터 작업이 압도적**이다.

| 작업 | NFS | SMB |
|------|-----|-----|
| 62k 파일 트리 스캔 | 0.16s | 67s (**420×**) |
| 대용량 순차 읽기 | 라인레이트 | 라인레이트 (동률) |

SMB는 파일마다 열기/속성/닫기 왕복이 쌓이고, NFS는 디렉터리 항목을 뭉텅이로 받는다(readdirplus).
