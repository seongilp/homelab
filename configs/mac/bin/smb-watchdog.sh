#!/bin/bash
# smb-watchdog.sh — msg10p의 zpool/zpool2 SMB 마운트를 유지한다.
# 2026-08-04: nfs-watchdog.sh 를 대체. NFS는 macOS에서 Finder 통합·확장속성·
# 인증 처리가 부실해 SMB로 전환했다. 자격증명은 키체인에 저장돼 있어야 한다
# (최초 1회 mount_smbfs 수동 실행으로 등록).
#
# launchd(com.zihado.smb-watchdog)가 60초마다 호출한다.
set -u

SERVER=192.168.123.104
USER_NAME=zihado
# 2026-08-07: WIRED_IF=en8 로 고정했더니 어댑터를 10G(AQC113, en15)로 교체하자
# 이름이 바뀌어 마운트가 멈췄다. 특정 인터페이스명 대신 "Wi-Fi가 아닌 경로"로 판별한다.
BASE="$HOME/nas-mnt"
SHARES="zpool zpool2"
LOG="$HOME/Library/Logs/smb-watchdog.log"
# 인증 실패 표시 파일. 존재하면 재시도 간격을 늘린다(계정 잠금·로그 폭주 방지).
AUTHFAIL="$HOME/Library/Logs/.smb-watchdog-authfail"
AUTHFAIL_BACKOFF=900            # 인증 실패 후 재시도까지 대기(초)

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$LOG"
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# 마운트가 살아있는지 확인. mount 목록에 있어도 서버가 죽으면 stat이 멈추므로
# 타임아웃을 걸어 실제 응답을 본다.
alive() {
  local mp=$1
  mount | grep -q "on $mp (smbfs" || return 1
  # -t 는 GNU coreutils. macOS 기본에는 timeout 이 없어 백그라운드+kill 로 대체.
  ( /bin/ls "$mp" >/dev/null 2>&1 ) &
  local pid=$!
  local i=0
  while [ $i -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 1
    i=$((i + 1))
  done
  # set +m 으로 잡 제어 알림을 끈다. 안 그러면 bash가 "Killed: 9 (...)" 를
  # stderr 로 뱉어 launchd 로그를 채운다.
  set +m
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}

# 자격증명 파일(0600)이 있으면 그 비밀번호로 붙는다. 없으면 키체인에 맡긴다.
# 2026-08-07: 키체인 항목이 멀쩡한데도 mount_smbfs 가 인증 거부되는 일이 두 번
# 발생해, 백그라운드에서 확실히 동작하는 경로를 둔다.
# (nsmb.conf 에는 password 키워드가 없고 smbutil crypt 도 현재 macOS엔 없다)
CRED="$HOME/.config/backup/smb-cred"

mount_url() {
  local share=$1
  if [ -r "$CRED" ]; then
    # 비밀번호에 @ : / 등이 있어도 깨지지 않도록 퍼센트 인코딩한다
    local enc
    enc=$(CRED="$CRED" python3 -c 'import os,urllib.parse
print(urllib.parse.quote(open(os.environ["CRED"]).read().rstrip("\n"), safe=""))' 2>/dev/null)
    if [ -n "$enc" ]; then
      printf '//%s:%s@%s/%s' "$USER_NAME" "$enc" "$SERVER" "$share"
      return
    fi
  fi
  printf '//%s@%s/%s' "$USER_NAME" "$SERVER" "$share"
}

do_mount() {
  local share=$1 mp="$BASE/$1" err
  mkdir -p "$mp"
  # //user@host/share — 비밀번호는 키체인에서 가져온다.
  # 2026-08-05: 오류를 버리지 말 것. 키체인에 자격증명이 없어 매분 인증 실패하는데
  # 로그에 'mount FAILED' 만 남아 원인 파악에 시간이 걸렸다.
  err=$(mount_smbfs "$(mount_url "$share")" "$mp" 2>&1)
  local rc=$?
  [ -n "$err" ] && log "  └ $err"
  # 인증 실패는 재시도해도 소용없고 계정 잠금 위험만 있다 → 백오프 표시를 남긴다
  case "$err" in
    *Authentication*|*authentication*) touch "$AUTHFAIL" ;;
  esac
  return $rc
}

# 서버로 가는 경로가 유선인지 확인한다. 무선으로 붙으면 굳이 마운트하지 않는다
# (대용량 접근이 무선 대역을 잡아먹고, 이동 중 끊김이 잦아 좀비 마운트가 생긴다).
route_if=$(route -n get "$SERVER" 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$route_if" ] || exit 0

# Wi-Fi 장치명을 하드코딩하지 않고 조회한다 (보통 en0 이지만 보장되지 않는다)
wifi_if=$(networksetup -listallhardwareports 2>/dev/null \
          | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
[ "$route_if" = "$wifi_if" ] && exit 0

# 경로 인터페이스에 실제로 IP가 붙어 있는지 확인
ipconfig getifaddr "$route_if" >/dev/null 2>&1 || exit 0

# 서버가 445 포트를 받는지 먼저 확인 — 죽은 서버에 mount를 걸면 오래 멈춘다
nc -z -G 3 "$SERVER" 445 >/dev/null 2>&1 || exit 0

# 직전에 인증이 실패했다면 백오프. 키체인에 자격증명이 생기면 자동으로 풀린다.
if [ -f "$AUTHFAIL" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$AUTHFAIL" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$AUTHFAIL_BACKOFF" ]; then
    exit 0
  fi
  rm -f "$AUTHFAIL"
fi

for share in $SHARES; do
  mp="$BASE/$share"
  if alive "$mp"; then
    continue
  fi
  # 응답 없는 좀비 마운트는 강제로 떼고 다시 붙인다
  if mount | grep -q "on $mp (smbfs"; then
    log "stale mount, forcing umount: $mp"
    umount -f "$mp" 2>/dev/null
  fi
  if do_mount "$share"; then
    log "mounted: $share"
    # 네트워크 볼륨 Spotlight 인덱싱 비활성 (재마운트 때마다 초기화될 수 있음)
    mdutil -i off "$mp" >/dev/null 2>&1
  else
    log "mount FAILED: $share"
  fi
done
