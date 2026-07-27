# Network

## 멀티기가 전환 (1G → 2.5G)

USB 2.5G 이더넷 어댑터(Realtek RTL8156/8157)로 주요 노드를 2.5G로 올렸다.
스위치의 RJ45 포트가 2.5G라, 5G 칩(8157)을 꽂아도 링크는 2.5G로 협상된다 —
**병목은 드라이버가 아니라 스위치**이므로 범용 드라이버(cdc_ncm)로도 라인레이트가 나온다.

| 구간 | 실측 |
|------|------|
| Mac ↔ prodesk | 2.34 Gbps (재전송 0) |
| Mac ↔ msg10p | 2.35 Gbps |
| prodesk ↔ msg10p | 2.35 Gbps |

### 교훈: 대역폭 ≠ 지연

Wi-Fi(802.11ax, 신호 -45dBm)로도 링크 속도는 960Mbps였지만, **왕복 지연(RTT)이 16ms로 출렁여서**
파일 많은 작업이 느렸다. 유선 전환 후 RTT <1ms. "5GHz니까 빠르다"는 대역폭 얘기일 뿐,
메타데이터 왕복이 잦은 워크로드는 지연이 지배한다.

## 링크 이중화 (자동 페일오버)

물리적으로 다른 두 NIC을 두고 route metric으로 우선순위를 준다. 주 링크가 죽으면 자동 전환.

```
# msg10p — USB 2.5G 주력 / 내장 1G 대기
nmcli con mod "<usb>"  ipv4.route-metric 100   # 우선
nmcli con mod "eno1"   ipv4.route-metric 200   # 대기
```

- **msg10p**: USB 2.5G (metric 100) → 내장 1G (metric 200)
- **prodesk**: 유선 2.5G (metric 102, `.111`) → Wi-Fi (metric 600, `.109`)

주소는 **라우터 DHCP 예약**으로 MAC에 고정한다. NetworkManager 수동 IP와 라우터 예약을
양쪽에서 걸면 충돌 소지가 있으니 한 곳에서만 관리한다.

> 예약은 MAC에 묶인다. **랜카드를 갈면 예약이 안 따라온다** — 2026-07-27에 prodesk
> 어댑터를 교체했더니 `.116` 예약이 무효가 되어 `.111`을 받았고, 그 주소를 참조하던
> 여섯 곳이 한꺼번에 끊겼다. 아래 [참조 추적](#주소를-바꾸면-참조를-전부-찾아야-한다) 참고.

### 폴백은 살아 있을 때만 폴백이다

이중화를 걸어두면 안심하게 되는데, **대기 링크가 조용히 죽어 있으면 이중화가 아니다.**

2026-07-27에 prodesk 무선이 DHCP 임대를 잃고 IPv4 없이 L2만 붙어 있었다.
`nmcli`는 `connected`로 보고했고 SSID도 정상이었다 — 주소만 없었다.
그 상태에서 유선을 뽑자 NetworkManager가 **IPv4가 없는 무선을 기본 경로로 세웠고**,
prodesk는 LAN·Tailscale·터널이 전부 끊긴 완전 고립 상태가 됐다.

```bash
nmcli con up <무선>          # 재연결 한 번으로 즉시 임대 획득
```

임대 만료 후 NM이 갱신을 포기하고 방치한 것이었다. 배운 것은 둘이다.

- **`connected`는 IPv4가 있다는 뜻이 아니다.** `ip -br -4 addr`로 주소를 직접 확인해야 한다
- 폴백은 **주기적으로 실제 통신을 시켜봐야** 산 것인지 안다 (`ping -I <폴백> <목적지>`)

### default metric만 보면 속는다 — 같은 서브넷은 링크 경로가 이긴다

prodesk가 유선(metric 100)·무선(metric 600) 둘 다 붙어 있는데도 **NAS 트래픽이 전부
무선을 타고 있었다.** 백업이 2.5G의 3분의 1 속도로 돌고 있었는데 아무도 몰랐다.

```
default via .1 dev <유선> metric 100    ← 여기만 보면 유선이 우선
default via .1 dev <무선> metric 600
192.168.123.0/24 dev <무선> metric 600  ← 그런데 링크 경로가 무선에만 있었다
```

`default`는 **서브넷 밖으로 나갈 때** 쓰는 경로다. 같은 `/24` 안에 있는 NAS로는
`192.168.123.0/24` 링크 경로가 선택되는데(longest prefix match), 그게 무선에만 있었다.
무선을 수동 IP로 잡아둔 탓에 NM이 무선에만 링크 경로를 깔았던 것.

**확인은 `ip route`가 아니라 `ip route get <목적지>`로 한다.**

```bash
ip route get 192.168.123.100      # 실제로 어느 인터페이스로 나가는지
```

고친 뒤 실측: **760~938 Mbps → 2,125 Mbps** (SSH 암호화 포함, 2.3배).

## USB 랜카드가 조용히 죽는 법

prodesk의 2.5G USB 어댑터(iptime, `0:e0:4c` OUI)가 **3일간 686번** 버스에서 사라졌다 돌아왔다.
그동안 아무 알림도 없었다.

```
r8152-cfgselector 2-3: USB disconnect, device number 57
r8152 … : Tx status -108              ← ESHUTDOWN, 전송 중 끊김
usb 2-3: new SuperSpeed USB device number 58
r8152 … : renamed from eth0           ← 드라이버 재probe
r8152 … : carrier on                  ← 4초 뒤 복구
```

**링크 플랩이 아니라 USB 장치 재열거다.** 이게 안 보이는 이유가 있다.

- 4초 만에 복구된다
- 인터페이스 이름이 `enx<MAC>` 형식이라 **재열거돼도 이름이 그대로**다
- IP도 그대로 돌아온다
- `ethtool`은 평소에 `2500Mb/s Full, Link detected: yes`로 멀쩡하다

증상은 엉뚱한 곳에서 터졌다. cloudflared가 `network is unreachable`로 재연결을 반복했고,
Beszel이 prodesk 경유 VM들을 `down`으로 오보했다. **어제 그걸 무선 탓으로 결론지었는데
절반만 맞았다** — 유선 어댑터도 같은 증상을 내고 있었다.

### 진단: 링크 문제와 버스 문제를 가른다

```bash
journalctl -k -b | grep -c "USB disconnect"      # 재열거 횟수 (정상이면 0)
journalctl -k -b | grep "renamed from eth0"      # 있으면 드라이버 재probe = 버스 문제
cat /sys/bus/usb/devices/<포트>/devnum           # 부팅 후 커진 만큼 재열거됐다
ip -s link show <nic>                            # errors 가 0이면 링크는 정상
```

`renamed from eth0`가 핵심 단서다. 링크만 끊긴 거라면 `carrier off/on`만 남지
드라이버가 다시 붙지는 않는다.

배제할 것들도 미리 확인해 두면 교체 판단이 빨라진다.

| 확인 | 정상이면 |
|------|---------|
| `<포트>/power/control` | `on` = autosuspend 이미 비활성 → 전원관리 원인 아님 |
| `ethtool` Speed/Duplex | 협상은 정상 → 케이블·스위치 협상 문제 아님 |
| `ip -s link` errors | 0 → 프레임 손상 아님 |

셋 다 정상인데 재열거만 반복되면 **어댑터 하드웨어**다. 교체 후 즉시 0회가 됐다.

### 주소를 바꾸면 참조를 전부 찾아야 한다

어댑터를 갈면 MAC이 바뀌고, **DHCP 예약은 MAC에 묶여 있으므로 무효가 된다.**
prodesk는 `.116` → `.111`로 바뀌었고 여섯 곳이 동시에 끊겼다.

| 참조 위치 | 성격 |
|---|---|
| Cloudflare 터널 ingress | 원격 SaaS 설정 |
| msg10p `/etc/exports` ×3 | 다른 서버의 접근 제어 |
| ebs 백업 스크립트 `PRODESK=` | 다른 서버의 스크립트 |
| Beszel DB (`systems` 테이블) | **애플리케이션 DB 안** — grep에 안 잡힌다 |
| `~/.ssh/config` | 로컬 |
| `docs/*.md` | 문서 |

터널 ingress는 아예 **`localhost`로 바꿨다.** cloudflared가 그 호스트 안에서 도니
IP 변동에 영향받을 이유가 없었다. 참조를 고치는 것보다 **참조를 없애는 게** 낫다.

## NFS 자동복구 워치독

NFSv3는 연결이 한 번 끊기면 스스로 복구하지 않는다. 서버 네트워크를 손볼 때마다
마운트가 죽는 걸 막기 위해 클라이언트(Mac)에 워치독을 둔다.

```bash
# 60초마다 launchd가 실행 — 마운트가 죽었으면 빠른 경로로 재마운트
for share in zpool zpool2; do
    mp="$BASE/$share"
    mount | grep -q " $mp " && ls "$mp" >/dev/null 2>&1 && continue
    umount -f "$mp" 2>/dev/null
    mount -t nfs -o nolocks,locallocks,nfc,rsize=65536,wsize=65536,soft,intr \
        "$FAST_IP:/$share" "$mp"
done
```

죽은 마운트를 ~10초 내 자동 복구. macOS의 autofs는 SIP 환경에서 다루기 까다로워
launchd StartInterval 워치독이 더 단순하고 확실했다.

### macOS NFS 클라이언트 주의점

`/etc/nfs.conf`:
```
nfs.client.mount.options = locallocks,nfc,rsize=65536,wsize=65536
```
- `locallocks` 없으면 Quick Look/sips가 NFS 잠금에서 실패 (`nolocks`는 오히려 error 13)
- `nfc` 없으면 Apple 프레임워크가 **한글 경로만** 실패 — 서버는 NFC인데 NFD로 조회하기 때문

## OOB 원격 콘솔 (NanoKVM)

컴퓨트 노드(prodesk)는 헤드리스라, OS가 죽으면 SSH로는 손을 못 댄다. 그래서
**하드웨어 레벨 원격 콘솔**을 하나 물려뒀다 — Sipeed **NanoKVM** (RISC-V 임베디드 보드).

```
  운영자 ──(LAN or Tailscale)──▶ NanoKVM ──HDMI(캡처)+USB(가상 키보드/마우스/USB)──▶ prodesk
```

- **SSH가 못 하는 걸 한다**: SSH는 OS 커널·sshd가 살아있어야 하지만, NanoKVM은
  HDMI 출력을 캡처하고 USB HID를 흉내 내므로 **BIOS 화면·부트로더·커널 패닉·재설치**
  화면까지 그대로 보고 조작한다. 사실상 "물리적으로 앞에 앉은 것"과 동급.
- **주 용도**: 부팅 실패 복구, BIOS 설정, 가상 USB로 ISO 마운트 후 OS 재설치, 원격 전원/리셋.
- **원격 접속**: 장비에 Tailscale을 올려 tailnet에 편입 → 집 밖에서도 웹UI 접속.
  prodesk가 완전히 먹통이어도 밖에서 살릴 수 있는 **최후의 수단**.
- **교훈**: 헤드리스 서버를 원격에서 운영하려면 "OS가 죽었을 때"를 대비한 대역외(out-of-band)
  경로가 하나 있어야 한다. IPMI/iLO가 없는 소비자용 미니 PC엔 IP-KVM이 그 역할을 대신한다.
  (prodesk를 책상에서 떨어뜨려 부팅 불능이 됐던 적이 있어 그 필요성을 체감했다.)
