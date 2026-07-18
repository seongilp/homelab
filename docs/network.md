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
- **prodesk**: 유선 2.5G (metric 100) → Wi-Fi (metric 600) — 리눅스가 유선을 자동 우선

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
