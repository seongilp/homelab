# UPS (무정전 전원장치)

상시 서비스 13종이 도는 ebs에 **Eaton Ellipse ECO 650** (650VA)을 물렸다.
USB로 연결하고 **NUT**(Network UPS Tools)로 감시·자동 셧다운을 건다.

현재 부하 15% (~78W) 기준 **예상 런타임 약 26분**.

## 구성 (NUT standalone)

```
Eaton UPS ──USB──▶ usbhid-ups(드라이버) ──▶ upsd(서버) ──▶ upsmon(감시)
                                                              │ 배터리 임계(20%) 도달 시
                                                              └─▶ shutdown -h +0
```

```ini
# /etc/nut/ups.conf
[eaton]
    driver = usbhid-ups
    port = auto
```

`nut.conf`는 `MODE=standalone`. upsd 계정(`upsd.users`)과 `upsmon.conf`의
`MONITOR eaton@localhost 1 <user> <pw> primary`까지 걸면, 정전 → 배터리 20% 도달 시
**깨끗한 셧다운**이 자동으로 돈다. UPS 없이 방전으로 죽으면 SQLite 쓰는 서비스들이
위험하니, "전원 보호"가 아니라 **"안전한 종료"까지가 UPS 설치의 완성**이다.

## 삽질: 드라이버가 "Driver not connected"

설치 직후 `upsc`가 `Driver not connected`만 뱉었다. 디버그 모드로 직접 돌려보면 바로 나온다.

```bash
/usr/libexec/nut/usbhid-ups -a eaton -D
# → Failed to open device (0463/FFFF): Access denied (insufficient permissions)
```

**nut 유저가 USB 장치를 못 여는 권한 문제**였다. 패키지가 udev 규칙
(`62-nut-usbups.rules`)을 깔아주지만, **UPS를 규칙 설치 전에 이미 꽂아뒀으면 적용이 안 된다.**

```bash
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=usb --action=add
# /dev/bus/usb/... 소유 그룹이 root → nut 으로 바뀐다
```

- 드라이버 문제는 `systemctl status`보다 **드라이버 바이너리를 `-D`로 직접** 돌리는 게 빠르다
- Ubuntu의 NUT 드라이버 경로는 `/lib/nut`이 아니라 `/usr/libexec/nut`
- 수동 실행(`upsdrvctl`)과 systemd 유닛(`nut-driver@eaton`)을 섞으면 충돌한다 — 확인은 수동, 운영은 유닛으로

## 일일 리포트 (텔레그램)

매일 09:00 cron이 `upsc` 요약을 텔레그램으로 보낸다 (`/usr/local/bin/ups-report.sh`).

```
🔋 UPS 일일 리포트 (ebs · Eaton Ellipse ECO 650)
상태: OL CHRG
배터리: 100% (예상 런타임 26분)
부하: 15% (78W)
출력 전압: 230.0V
```

- 상태가 `OL`(on-line)이 아니면 ⚠️ 로 바뀐다 — `OB`(on battery)면 정전 중
- `upsc` 무응답이면 그것대로 알린다 — **감시가 죽은 것도 알려야 감시다** ([backup.md](backup.md)의 죽은 백업 탐지와 같은 원칙)
- 토큰은 `~/.env`에서 읽는다 (스크립트에 하드코딩 없음)

## 조회 치트시트

```bash
upsc eaton                     # 전체 상태
upsc eaton ups.status          # OL=상시전원 OB=배터리 LB=배터리부족 CHRG=충전중
upsc eaton battery.runtime     # 남은 런타임(초)
```
