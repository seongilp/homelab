# homelab

개인 홈랩 구성 기록. 스토리지 · 컴퓨트 · 백업 · 네트워크를 직접 운영하며 정리한 문서입니다.

> 설계 원칙: **지루하고 안정적인 것이 미덕.** 검증된 조합(ZFS, rsync, restic)을 쓰고,
> 장애를 미리 설계하며(이중화·자동복구), 튜닝은 감이 아니라 실측으로 합니다.

## 구성 요약

| 노드 | 하드웨어 | 역할 | OS | 네트워크 |
|------|----------|------|-----|----------|
| **msg10p** | HP ProLiant MicroServer Gen10+ (Xeon E-2224, 64GB ECC) | 스토리지 / 백업 서버 | Rocky Linux 9.8 | 2.5G + 1G 자동 페일오버 |
| **prodesk** | HP EliteDesk 800 G6 (i9-10900, 64GB) | 컴퓨트 / 랩 | Ubuntu 26.04 LTS | 2.5G 유선 + Wi-Fi 폴백 |
| **ebs** | Lenovo ThinkCentre M72e (i3-3220T, 16GB) | 상시 서비스 (봇·러너·터널) | Ubuntu 26.04 LTS | 1G |
| **Mac** | MacBook Pro | 워크스테이션 | macOS | 2.5G (Thunderbolt) |

VM: FreeBSD 15.1-RELEASE + 16.0-CURRENT (prodesk libvirt/KVM, 커널 학습용)

## 문서

- [network.md](docs/network.md) — 2.5G 멀티기가 전환, 링크 이중화, NFS 자동복구
- [storage.md](docs/storage.md) — ZFS 풀 레이아웃, 튜닝(ARC/recordsize), 디스크 검증
- [backup.md](docs/backup.md) — 3-2-1 다층 백업 (rsync + restic + kopia + 오프사이트)
- [shell.md](docs/shell.md) — bash + starship 표준 셸 환경

## 원칙으로 삼은 것들

- **3-2-1 백업** — 사본 3벌, 매체 2종, 오프사이트 1벌
- **CMR 디스크만 ZFS에** — SMR은 리실버에서 죽는다
- **미러의 심장은 이중화** — special vdev/메타데이터는 단일 장치 금지
- **측정 후 튜닝** — 병목을 구간별로 분리해 진짜 원인만 고친다
- **장애를 기본값으로** — 링크·마운트는 죽어도 자동 복구되게 설계

---

*이 리포는 구성 문서(쇼케이스)입니다. 실제 IaC(Terraform/Ansible/GitOps)와 자격증명이 얽힌
운영 스크립트는 별도 private 리포에서 관리합니다.*
