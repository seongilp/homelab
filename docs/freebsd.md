# FreeBSD Lab

리눅스/운영 배경에서 **시스템 내부와 커널**로 파고들기 위한 학습 환경.
prodesk의 libvirt/KVM 위에 두 개의 VM을 두고 실습한다.

```
freebsd   — 15.1-RELEASE   안정 브랜치. buildworld·jail·pkgbase 실습
fb-crnt   — 16.0-CURRENT   개발 브랜치. 커널 모듈·최신 기능 추적
```

두 VM 모두 cloud-init(nuageinit) 자동 프로비저닝, ZFS 루트, 공통 셸 환경(bash+starship).
VM 디스크는 `data/vms` 데이터셋(recordsize=64K, atime=off)에 raw로 분리해
`zfs snapshot`으로 VM 단위 스냅샷이 가능하다.

## 실습 로그

### 1일차 — base system

- **buildworld + buildkernel** 완주 (첫 빌드 ~88분). 소스에서 OS 전체를 빌드하는 경험
- `echo.c` 첫 수정 — base 유틸리티를 직접 고쳐보며 소스 트리 구조 파악
- `rc.conf`/`sysrc`, **pkgbase**(base를 패키지로 관리), `bectl`(부트환경) 학습
- **jail 2종** 구축 — pkgbase 최소 구성 `mini`(105M, FreeBSD-runtime+rc)

### 2일차 — jail + ZFS

- jail 안에 sqlite3 설치(ports 저장소 연결)
- **ZFS 스냅샷으로 DB 복구 시연** — snapshot → DELETE → rollback으로 데이터 복원
- 실증 삽질: `pkg -r` 저장소 설정 (REPOS_DIR 두 곳 + keys 복사 필요)

### 커널 학습 (진행 중)

로드맵: **KLD hello 모듈 → 커스텀 KERNCONF → 시스템콜 추적 → DTrace → 전공 분야**

- **1단계 완료**: `hello.ko` 커널 모듈 작성·로드 (fb-crnt에서)
- fb-crnt 증분 buildworld ~131초 체험 (전체 대비 극적 단축)
- 교재: McKusick, *The Design and Implementation of the FreeBSD Operating System* (2판)

## 왜 FreeBSD인가

- **일관된 base system** — 커널 + userland + 문서가 한 소스 트리. 리눅스의 배포판 파편화와 대비
- **ZFS 1급 시민** — 이 홈랩의 스토리지 철학과 직결 ([storage.md](storage.md))
- **jail** — 컨테이너의 원류. 가볍고 투명한 격리
- **읽기 좋은 코드베이스** — 커널 내부를 학습하기에 정제된 소스

리눅스로 운영을, FreeBSD로 내부 원리를 — 두 세계를 오가며 시스템을 더 깊이 이해한다.
