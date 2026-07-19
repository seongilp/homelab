# homelab

개인 홈랩 구성 기록. 스토리지 · 컴퓨트 · 백업 · 네트워크를 직접 운영하며 정리한 문서입니다.

> 설계 원칙: **지루하고 안정적인 것이 미덕.** 검증된 조합(ZFS, rsync, restic)을 쓰고,
> 장애를 미리 설계하며(이중화·자동복구), 튜닝은 감이 아니라 실측으로 합니다.

## 구성 요약

| 노드 | 하드웨어 | 역할 | OS | 네트워크 |
|------|----------|------|-----|----------|
| **msg10p** | HP ProLiant MicroServer Gen10+ · Xeon E-2224 (4c) · 64GB ECC · SK hynix 1TB NVMe(root) + HGST 10TB×2 + WD Red 4TB×2 (ZFS 미러) | 스토리지 / 백업 서버 | Rocky Linux 9.8 | 2.5G + 1G 자동 페일오버 |
| **prodesk** | HP EliteDesk 800 G6 Mini · i9-10900 (10c/20t) · 64GB · Crucial MX500 1TB(root) + WD SN750 500GB NVMe(ZFS) | 컴퓨트 / 랩 | Ubuntu 26.04 LTS | 2.5G 유선 + Wi-Fi 폴백 |
| **ebs** | Lenovo ThinkCentre M72e Tiny · i3-3220T (2c/4t) · 16GB · Crucial M500 240GB SATA SSD | 상시 서비스 (웹앱·봇 13종 self-host, ex-Cloudflare Workers · 터널) | Ubuntu 26.04 LTS | 1G |
| **Mac** | MacBook Pro (Mac16,8) · **M4 Pro** (14c: 10P+4E) · 48GB · Apple SSD AP1024Z (1TB NVMe) | 워크스테이션 | macOS 26.4 | 2.5G (Thunderbolt) + Wi-Fi 폴백 |

VM: FreeBSD 15.1-RELEASE + 16.0-CURRENT (prodesk libvirt/KVM, 커널 학습용)

## 토폴로지

```
                    인터넷
                      │
                 [LG U+ GW] ──────── Tailscale (원격 접속)
                      │
              ┌───── 2.5G 스위치 ─────┐
              │         │        │    │
           ┌──┴──┐   ┌──┴──┐  ┌──┴──┐ └──┐(1G)
           │ Mac │   │msg10p│  │prodesk│  │ ebs │
           │2.5G │   │2.5G  │  │ 2.5G  │  │ 감시 허브
           └─────┘   └──┬──┘  └───┬───┘  └──┬──┘
            워크        ZFS 26T    │(libvirt)  │
            스테이션   미러 2풀    │           │
                                ┌─┴─┐       Beszel
                          freebsd  fb-crnt   모니터링
                          (15.1)  (CURRENT)   ← 5노드 감시

  네트워크 이중화: msg10p·prodesk·Mac 모두 주 링크(2.5G) 죽으면 자동 폴백
  백업 흐름: Mac ─rsync/restic→ msg10p(로컬) ─restic→ 클라우드(오프사이트)
```

## 문서

- [cloudflare-migration.md](docs/cloudflare-migration.md) — Workers 13종을 ebs로 이관 (어댑터 설계·캐시 계층·p99 튜닝)
- [network.md](docs/network.md) — 2.5G 멀티기가 전환, 링크 이중화, NFS 자동복구
- [storage.md](docs/storage.md) — ZFS 풀 레이아웃, 튜닝(ARC/recordsize), 디스크 검증
- [backup.md](docs/backup.md) — 3-2-1 다층 백업 (rsync + restic + kopia + 오프사이트)
- [monitoring.md](docs/monitoring.md) — Beszel 대시보드 + 텔레그램 알림 (NAT 뒤 VM 연결)
- [shell.md](docs/shell.md) — bash + starship 공통 셸 환경 (+ fish 선택)
- [freebsd.md](docs/freebsd.md) — FreeBSD 학습 랩 (buildworld·jail·커널 모듈)
- [emacs.md](docs/emacs.md) — Emacs/Doom/Magit 치트시트 (커널 소스 탐색·git 작업)

## 원칙으로 삼은 것들

- **3-2-1 백업** — 사본 3벌, 매체 2종, 오프사이트 1벌
- **CMR 디스크만 ZFS에** — SMR은 리실버에서 죽는다
- **미러의 심장은 이중화** — special vdev/메타데이터는 단일 장치 금지
- **측정 후 튜닝** — 병목을 구간별로 분리해 진짜 원인만 고친다
- **장애를 기본값으로** — 링크·마운트는 죽어도 자동 복구되게 설계

---

*이 리포는 구성 문서(쇼케이스)입니다. 실제 IaC(Terraform/Ansible/GitOps)와 자격증명이 얽힌
운영 스크립트는 별도 private 리포에서 관리합니다.*
