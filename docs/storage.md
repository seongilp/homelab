# Storage (ZFS)

## 풀 레이아웃

### msg10p — 두 미러 풀 (장애 격리)

```
zpool   9.09T  (53% 사용)   — 활성 백업 타깃 + 아카이브
└─ mirror-0
   ├─ HGST HUH721010ALE604  (10TB, CMR)
   └─ HGST HUH721010ALE604  (10TB, CMR)

zpool2  3.62T  (74% 사용)   — 외부에서 가져온 정적 사본
└─ mirror-0
   ├─ WD Red Plus WD40EFZX  (4TB, CMR)
   └─ WD Red Plus WD40EFZX  (4TB, CMR)

nvme0n1 (SK hynix 1TB)      — OS(root) 전용, 풀 미포함
```

두 풀을 **일부러 분리**했다. 오래된 중고 디스크(zpool2)가 죽어도 주 백업 풀(zpool)은 무사하도록.
역할도 갈라 두었다 — **`zpool`은 매일 쓰기가 일어나는 활성 백업 타깃**,
**`zpool2`는 한 번 부어넣고 늘지 않는 정적 사본**(외장드라이브·클라우드 덤프).

**주요 데이터셋** (2026-07-26 기준)

| 데이터셋 | 용량 | recordsize | 압축 | 용도 |
|----------|------|-----------|------|------|
| `zpool/ds920p` | 4.06T | 128K | lz4 | 퇴역한 Synology DS920+ 전체 덤프 |
| `zpool/photos` | 283G | **1M** | on | 사진 원본 아카이브 (2001년~) |
| `zpool/restic/mac` | 247G | 128K | zstd | restic 리포 — `~/work`, `~/Downloads` |
| `zpool/backup` | 247G | 128K | lz4 | rsync 평문 미러 + ebs/prodesk 백업 수신 |
| `zpool2/mac_backup` | 1.12T | 128K | lz4 | 외장드라이브 미러 |
| `zpool2/orico` | 686G | 128K | lz4 | 외장드라이브 미러 |
| `zpool2/icloud` | 639G | 128K | lz4 | Parachute iCloud 백업 |

### 이름이 곧 문서다

한동안 데이터셋 이름이 `rsync`, `fs1`, `fs2`였다. 만들 당시엔 자명했지만 반년 뒤엔
`rsync`가 "rsync로 받는 것"인지 "rsync 설정"인지 알 수 없었고, 실제로 매일 도는
백업 타깃으로 착각해 한참 헤맸다(실체는 **일회성 NAS 이관 덤프**였다).
`ds920p` / `archives` / `share`로 바꾸고 나서야 `zfs list` 한 번에 구조가 읽혔다.

**그리고 이름이 읽히자 중복이 드러났다.** `share`(63.5G)는 `zpool2/orico/정리필요/`와
같은 내용이었고, `archives`는 대부분 암호를 잃어 열 수 없는 repo였다. 이름이 `fs1`/`fs2`인
동안에는 비교해볼 생각조차 못 했다. **정리의 첫 단계는 삭제가 아니라 이름 붙이기다.**

restic 리포도 여기저기 흩어져 있던 것을 `zpool/restic/` 아래로 모았다.
**이름을 바꿀 때는 참조부터 훑는다** — 실제로 이 검색이 백업 repo 경로, rsync 데몬
모듈 설정, SELinux 파일 컨텍스트를 잡아냈다. 하나라도 놓쳤으면 다음 새벽에 조용히 실패했을 것.

```bash
grep -rn 'zpool/<옛이름>' /etc /usr/local ~/...
```

데이터셋 `mountpoint` 속성이 `default`(상속)이면 rename 시 마운트 경로가 자동으로 따라온다.
`local`로 고정해 두면 따라오지 않으니 확인이 필요하다.

### prodesk — NVMe 단일 풀

```
data  464G  (12% 사용)  — VM 이미지 (freebsd, freebsd-dev)
└─ nvme (WD Black SN750 500GB)   ※ 단일 vdev — 체크섬 감지만, 복구는 백업 의존
sda   (Crucial MX500 1TB, SATA)  — Ubuntu 시스템 + zen VM + ebs 백업 수신
```

단일 디스크 풀이라 자가 복구(미러)는 없지만 체크섬으로 손상은 감지된다.
(원래 Windows 듀얼부트였으나 밀고 ZFS로 전환)

**"복구는 백업 의존"이라고 써두고 정작 백업이 없었다.** 설계 문서에 적어둔 전제를
구현했는지는 별개 문제다. 2026-07-26에야 `data/vms` → `msg10p:zpool/backup/prodesk-vms`
일일 ZFS 증분 복제를 걸었다 → [backup.md](backup.md)

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
