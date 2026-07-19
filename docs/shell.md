# Shell

모든 노드(Linux 3대 + FreeBSD VM 2대)를 동일한 셸 환경으로 통일.

## 구성

- **bash (로그인 셸) + starship** — zsh/oh-my-zsh에서 이전 (시작 3.6s → 0.1s)
- **eza / bat** — 컬러 `ls`, 문법 하이라이팅 `cat`
- **fzf** — Ctrl+R 히스토리 퍼지검색, Ctrl+T 파일, Alt+C 디렉터리
- **bash-completion** — 문맥 인식 Tab 완성
- **fish** (선택) — 대화형 UX용. starship·eza·fzf·ls 래퍼를 bash와 동일하게 구성

공용 `starship.toml` 하나를 모든 노드에 배포. `ls -altr` 같은 GNU 손버릇은
eza 문법으로 자동 번역하는 래퍼 함수로 흡수.

## 왜 bash가 로그인 셸인가 (fish/zsh 아니고)

fish의 대화형 UX(자동완성·하이라이팅)는 훌륭하지만, **로그인 셸은 bash**로 둔다.

- **POSIX 호환** — 여러 서버를 ssh로 오가며 스크립트를 돌리는 환경. fish는 비-POSIX라
  `source some.sh`·`.bashrc` 스니펫이 안 통해 "어디서나 똑같이 동작"이 깨진다.
- **어디에나 기본 탑재** — Rocky·Ubuntu·FreeBSD 전부 bash 기본. fish는 별도 설치.
- **예쁜 건 starship이 담당** — fish를 쓰는 주 이유(프롬프트+완성)는 이미 starship+fzf로 bash에 얹었다.

정리: **fish = 대화형 UX 최고, bash = 어디서나 똑같이 동작.** 그래서 로그인은 bash,
쓰고 싶을 때 `fish`로 진입하는 하이브리드. 두 셸에 같은 프롬프트·별칭·래퍼를 배포해 경험을 맞췄다.

## 느렸던 것들, 왜 느렸나

### 셸 시작 3.6초

원인은 프롬프트가 아니라 **로딩되는 초기화 코드**였다.

- 삭제된 anaconda의 init 코드가 매번 헛실행
- SDKMAN/pyenv를 시작마다 전체 로딩

→ 전부 **lazy-load**로 전환 (첫 사용 시에만 로딩). 3.6s → 0.09s (**40×**).

### 거대 git 저장소에서 프롬프트 굼뜸

FreeBSD `/usr/ports`(디렉터리 3.2만 개)에서 엔터마다 ~5.9초 지연.
starship이 프롬프트마다 `git status`를 돌리는데 **untracked 파일 스캔**이 병목.

```bash
git config core.untrackedCache true   # 변경 안 된 디렉터리 재스캔 생략
git config feature.manyFiles true
git update-index --untracked-cache
```

→ 5.9s → 0.27s (**22×**). starship엔 `command_timeout` + git untracked 카운트 비활성으로 보강.

## 로그인 셸 함정

일부 도구가 만든 `~/.bash_profile`이 `~/.profile`을 가려서 로그인 셸이 `.bashrc`를
안 읽는 경우가 있다. `.bash_profile`에서 명시적으로 `.bashrc`를 source하게 보정.

## tmux (터미널 멀티플렉서)

긴 작업(buildworld 등)을 detach 해두고, ssh 끊겨도 계속 돌리는 용도. **oh-my-tmux**
(gpakosz/.tmux) 프레임워크로 모든 노드 상태바를 통일.

- 설치: `git clone gpakosz/.tmux ~/.tmux` → `.tmux.conf` 심링크 + `.tmux.conf.local` 커스텀
- 상태바: 세션명 · 업타임 · 시계 · 호스트명 (배터리는 노트북만)
- **창 이름 = 현재 디렉터리 자동** — `set -wg automatic-rename-format "#{b:pane_current_path}"`
  (여러 창 열었을 때 하단바로 `src` `org` `ports` 구분). 경로/브랜치 상세는 프롬프트(starship)가 담당해 역할 분담.
- alias: `t`=tmux, `tn 이름`=new, `tl`=list, `ta 이름`=attach, `tk 이름`=kill
- 리로드: `Ctrl+b r` (설정 고친 뒤)

**활용**: `tn build` → buildworld 실행 → `Ctrl+b d`(detach) → ssh 끊어도 계속 →
나중에 `ta build`로 재접속해 진행 확인. nohup보다 편하다.

> 함정 메모: `.tmux.conf.local`의 자동 rename에 `%hook after-new-window` 문법을 쓰면
> 구버전 tmux에서 syntax error. `set -wg automatic-rename on/format`만으로 충분.

## fb-dev는 fish 로그인 셸

FreeBSD 커널 개발 VM(`freebsd-dev`)은 예외적으로 **로그인 셸을 fish로** 전환.
(다른 노드는 위 원칙대로 bash 로그인.) 개발 전용이라 POSIX 스크립트 이식성보다
대화형 UX(자동제안·git 완성 내장)를 우선. Doom Emacs + clangd로 커널 소스를 탐색하는
워크스테이션 성격이라 Mac과 환경을 맞췄다. 원격 명령을 밖에서 넣을 땐 `bash -c`로 감싸야 함.
