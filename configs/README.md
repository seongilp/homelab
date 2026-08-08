# configs

실제 운영에 적용된 설정 파일 사본. 재구축 시 참조용이며, **여기를 고쳐도 서버에 반영되지 않는다**
(배포 자동화는 없다). 서버에서 바꾼 뒤 여기로 복사해 커밋하는 방향으로 관리한다.

자격증명은 포함하지 않는다. 모든 스크립트는 외부 파일에서 읽는다:
- `~/.config/backup/smb-cred` (0600) — SMB 비밀번호
- `~/.config/ilo/<호스트>.env` (0600) — iLO 계정
- `~/.config/backup/telegram.env` — 텔레그램 토큰

## msg10p

| 파일 | 용도 |
|---|---|
| `etc/samba/smb.conf` | macOS 최적화(fruit) + 10G 튜닝. 맥이 `~/nas-mnt/{zpool,zpool2}` 로 마운트 |
| `etc/exports` | NFS. prodesk 등 리눅스 클라이언트용. IP 대신 서브넷 지정 |
| `etc/sysctl.d/99-10g-tuning.conf` | 소켓 버퍼·backlog 상향. 기본값은 1G 기준이라 10G 에서 부족 |
| `etc/systemd/system/nic-tuning.service` | NIC 링 버퍼 1024→4096 (부팅 시 적용) |
| `etc/netplan/00-installer-config.yaml` | ens1(10G, metric 100) + eno2(1G 폴백, metric 500) |

### 왜 이렇게 했나

- **`server signing = disabled`** — 10G 에서 SMB3 서명은 CPU 병목이 된다. 신뢰된 사설망 전제.
- **`case sensitive = yes`** — 대소문자 무시 매칭은 이름 조회마다 디렉터리를 훑는다.
  ZFS 가 `casesensitivity=sensitive` 라 의미도 일치한다.
- **`strict allocate = no`** — `yes` 면 sparse/CoW 이점을 없애고 불필요한 쓰기를 만든다. ZFS 에서 금물.
- **`fruit:*`** — macOS 리소스 포크·확장속성 처리. `fruit:metadata` 는 데이터를 쓰기 시작한 뒤
  바꾸면 메타데이터가 유실되므로 고정.
- **링 버퍼 4096** — 드롭 카운터가 0 이라 최대치(8192)까지 올릴 이유가 없다.
  `ethtool -S ens1 | grep drop` 이 증가하면 그때 올린다.
- **netplan metric** — 10G 가 살아있으면 그쪽만 쓰고 죽으면 1G 로 자동 폴백.
  dhcp6 가 켜진 인터페이스는 v4/v6 metric 을 같이 지정해야 `netplan generate` 가 통과한다.

## mac

| 파일 | 용도 |
|---|---|
| `bin/smb-watchdog.sh` | SMB 마운트 유지. 좀비 마운트 감지 후 강제 재마운트 |
| `bin/ilo` | iLO(Redfish) CLI. 표준 라이브러리만 사용 |
| `bin/nsmb.conf` | macOS SMB 클라이언트 튜닝 → `~/Library/Preferences/nsmb.conf` |
| `LaunchAgents/com.zihado.smb-watchdog.plist` | watchdog 60초 주기 실행 |

### 알아둘 것

- **`smb-watchdog.sh`** 는 인터페이스명을 하드코딩하지 않는다. 어댑터를 바꾸면 이름이 달라져
  마운트가 멈추므로(2026-08-07 실제 발생) "Wi-Fi 가 아닌 경로"로 판별한다.
- **자격증명은 파일 우선, 키체인 폴백.** 키체인 항목이 멀쩡한데도 `mount_smbfs` 가 인증을
  거부하는 일이 반복돼(백그라운드라 키체인 승인 창에 답할 수 없음) 파일 경로를 두었다.
- **`nsmb.conf` 에는 password 키워드가 없다.** `smbutil crypt` 도 현재 macOS 에 없다.
