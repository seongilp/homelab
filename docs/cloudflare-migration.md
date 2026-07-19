# Cloudflare → 홈서버 이관

Cloudflare Workers에서 돌던 서비스 16개 중 13개를 하룻밤에 ebs(ThinkCentre Tiny)로
옮긴 기록. 목적은 비용 절감보다 **자유도** — 런타임 제약 해제, SQLite 직접 접근,
장기실행 작업. 나머지 3개는 남길 이유가 명확해서 남겼다(아래).

## 전체 그림

```
사용자 ─ Cloudflare 엣지 (DNS·TLS·캐시룰 120s) ─ cloudflared 터널 ─ ebs
                                                                  │
                                              ┌───────────────────┤
                                        마이크로캐시 (:83xx)   systemd 서비스 9개
                                        TTL 120s, HIT=sub-ms   + crontab 스케줄러
                                              │                   │
                                        Node 앱 (:84xx~:849x)  SQLite / 파일 KV / 파일 R2
```

- 도메인·TLS는 Cloudflare에 그대로 두고 **오리진만 Worker → 터널로 교체**.
  포트포워딩 없이 공개 서비스가 되고, 롤백은 DNS 되돌리기면 끝.
- 트래픽 규모(주 47만 요청 ≈ 0.8 req/s)는 i3-3220T로도 여유.

## 핵심 설계: worker-host 어댑터

Workers 코드를 **한 줄도 고치지 않고** Node로 실행하는 얇은 어댑터를 만들었다.
Workers API 중 실제로 쓰이는 표면만 재현한다:

| Workers | Node 구현 | 비고 |
|---|---|---|
| KV 바인딩 | 파일 1개 = 키 1개 (tmp+rename 원자 쓰기) | TTL은 사이드카 파일, `arrayBuffer`/`json` 타입 지원 |
| D1 | `node:sqlite` (WAL + busy_timeout) | `prepare/bind/first/all/run/raw/batch` |
| R2 | 파일 + 메타 사이드카 | `put/get/head/delete/list` (delimiter 포함) |
| Queues | 스풀 디렉터리 + 폴링 컨슈머 | ack/retry/dead-letter 재현 |
| 서비스 바인딩 | 형제 봇 in-process 로드 | gallery→builder 같은 의존 유지 |
| `caches.default` | 인메모리 LRU (s-maxage 존중) | colo 캐시 시맨틱과 동일하게 휘발 |
| cron 트리거 | host crontab (UTC→KST 변환) | 원본 표현식을 인자로 넘겨 `event.cron` 분기 보존 |

프레임워크 앱은 어댑터 대신 각자의 표준 경로로:

- **Next.js (OpenNext 배포본)** — `getCloudflareContext()`가 전역 심볼
  `Symbol.for("__cloudflare-context__")`를 읽는 점을 이용, `instrumentation.ts`에서
  심볼에 KV/D1 심을 주입. 앱 코드 무수정으로 `next build`(standalone) + systemd.
- **Nuxt (cloudflare_module 프리셋)** — `NITRO_PRESET=node-server` + rollup alias로
  `cloudflare:workers` 모듈을 호환 심으로 치환.

## 컷오버 절차 (서비스마다 반복)

1. 데이터 백업·이전: D1 덤프 → SQLite, KV/R2 전량 파일로
2. ebs에 배포 → **로컬에서 실데이터 검증** (여기까지 서비스 무중단)
3. CF cron 비활성화 → crontab 인계
4. 터널 ingress + DNS CNAME 전환 (워커 커스텀 도메인 해제)
5. 외부 검증 후 CF쪽 삭제는 **3중 백업 확인 후에만**

클라이언트에 workers.dev URL이 하드코딩된 것(토스 미니앱 등)은 도메인을 못 바꾸므로,
CF 워커를 **10줄짜리 터널 프록시로 교체**해 주소를 유지했다. 로직·데이터는 ebs에 있고
CF에는 전달자만 남는 패턴.

## 밟은 함정들

- **IPv6 없는 서버 + AAAA 있는 목적지 = ETIMEDOUT.** 텔레그램·CF 도메인 fetch가
  전부 타임아웃. GitHub API는 IPv4 전용이라 멀쩡해서 원인 찾기가 더 어려웠다.
  `dns.setDefaultResultOrder("ipv4first")` 한 줄로 해결.
- **SQLite 대량 임포트는 트랜잭션이 전부.** 2.1GB 덤프를 그냥 흘리면 INSERT마다
  fsync가 걸려 15시간짜리가 된다. `BEGIN; … COMMIT;` + `synchronous=OFF`로 3분.
- **Next standalone 경로 오염.** 홈 디렉터리의 락파일 때문에 트레이싱 루트가 `~`로
  잡혀 산출물이 중첩 경로로 나온다. `outputFileTracingRoot` 명시로 해결.
- **cron 분기는 표현식 문자열 매칭.** `event.cron`으로 분기하는 워커는 스케줄 시간을
  KST로 바꾸더라도 원본 UTC 표현식을 그대로 전달해야 한다.

## 성능: 실측 후 캐시 계층 복원

이관 직후 "느리다"의 원인은 두 가지였다 — 빈 캐시로 시작한 첫 방문 재계산과,
Workers가 하던 엣지 HTML/JSON 캐시의 소실. 계층을 둘 다 복원했다:

1. **CF Cache Rules** — HTML/JSON 엣지 캐시 120s (변경성 경로 제외). 글로벌 HIT 0.13s.
2. **오리진 마이크로캐시** — Node 80줄 프록시. 캐시 HIT은 보관된 Buffer를 그대로
   써서 요청당 할당이 없다(GC 스파이크 제거). Next.js의 요청당 5~8ms 오버헤드를
   sub-ms로 만든 핵심.

로컬 실측(keep-alive, 300샘플) — 17개 엔드포인트 전부 **p50 ≤ 2.8ms / p99 ≤ 6.7ms**.
curl로 재면 프로세스 스폰 오버헤드(~5ms)가 섞이므로 in-process로 재야 한다.

## 백업: ebs가 죽어도 되게

- `ebs-backup.sh`가 매일 03:30 코드+시크릿+파일KV/R2+**SQLite `.backup` 스냅샷**
  (가동 중 정합성 보장)+systemd 유닛+crontab을 prodesk·msg10p 두 곳에 rsync.
- 이관 시점의 CF 원본 스냅샷(워커 번들·D1 덤프·KV 전량)은 Mac에 별도 보관.
- 복구 = 백업 디렉터리 복사 + 유닛 파일 설치 + crontab 복원. 전부 백업 안에 있다.

## Cloudflare에 남긴 것 (남긴 이유)

| 항목 | 이유 |
|---|---|
| WebRTC 서비스 1개 | Cloudflare Calls(SFU) 의존 — 옮기려면 LiveKit급 재개발 |
| Pages 정적 사이트 15개 | 무료 글로벌 CDN을 버리고 홈 대역폭으로 정적 서빙할 이유가 없다 |
| 오프사이트 백업 R2 254GB | 홈서버로 옮기면 "오프사이트"가 아니게 된다 |
| 얇은 프록시 워커 3개 | 클라이언트에 박힌 구 URL 전달자 (스토어 재배포 회피) |

비용은 Workers Paid $5 + Pro $25 강등으로 월 $30 절감 예정(빌링 API가 500을 뱉어
지원 티켓으로 처리 중), R2 사용량 ~$4/월만 남는다.

## 배운 것

- **엣지가 하던 일은 사라지지 않는다, 자리만 옮긴다.** KV·D1·엣지캐시·cron·큐 전부
  로컬 등가물이 있고, 대부분 파일시스템과 crontab으로 충분했다.
- **어댑터 > 재작성.** 13개 서비스를 코드 수정 없이 옮긴 건 "Workers API의 실사용
  표면이 좁다"는 관찰 덕. 전체 호환 대신 쓰는 것만 충실히 재현했다.
- **삭제는 백업 개수를 센 다음에.** CF쪽 정리는 사본 3벌(ebs·prodesk·msg10p) 확인
  후에만 진행했다.
