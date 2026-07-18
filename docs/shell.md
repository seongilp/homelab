# Shell

모든 노드(Linux 3대 + FreeBSD VM 2대)를 동일한 셸 환경으로 통일.

## 구성

- **bash + starship** — zsh/oh-my-zsh에서 이전 (시작 3.6s → 0.1s)
- **eza / bat** — 컬러 `ls`, 문법 하이라이팅 `cat`
- **fzf** — Ctrl+R 히스토리 퍼지검색, Ctrl+T 파일, Alt+C 디렉터리
- **bash-completion** — 문맥 인식 Tab 완성

공용 `starship.toml` 하나를 모든 노드에 배포. `ls -altr` 같은 GNU 손버릇은
eza 문법으로 자동 번역하는 래퍼 함수로 흡수.

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
