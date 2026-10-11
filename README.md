# git mirrors

`mirror.sh` 는 여러 저장소를 `git clone --mirror` 로 백업/관리하는 단일 스크립트입니다.
미러는 `<owner>/<repo>.git` 형태의 bare 저장소로 보관됩니다.

## 요구 사항

- `bash`, `git`
- 색상은 tty 에서 자동 활성화되며 `NO_COLOR` / `FORCE_COLOR` 로 제어할 수 있습니다.

## 레이아웃

```
<owner>/<repo>.git/     # mirror (bare)
mirror.sh
```

## 사용법

### clone

원격 저장소를 미러로 복제합니다. URL 에서 `owner/repo` 를 추출해 `<owner>/<repo>.git` 에 저장합니다.

```console
$ ./mirror.sh clone git@github.com:octocat/Hello-World.git
[clone] octocat/Hello-World.git
  remote   git@github.com:octocat/Hello-World.git
  head     master @ 7fd1a60
  refs     1 branches, 0 tags
  size     1.2M
```

여러 개를 한 번에 지정할 수 있고, 이미 존재하면 skip 합니다.

```console
$ ./mirror.sh clone https://github.com/example/demo-app.git git@github.com:example/widget.git
```

### list

미러 목록과 요약 정보를 출력합니다.

```console
$ ./mirror.sh list
MIRROR                  HEAD                REFS                  UPDATED    SIZE
octocat/Hello-World.git master@7fd1a60      1 branches, 0 tags    3m ago     1.2M
example/demo-app.git    main@1a2b3c4        5 branches, 3 tags    1h ago     8.4M
```

- `HEAD` — 기본 브랜치와 최신 커밋
- `REFS` — 브랜치/태그 개수
- `UPDATED` — 마지막 fetch 이후 경과 시간
- `SIZE` — 미러 크기

### update

모든 미러를 `git remote update --prune` 으로 최신화합니다.

```console
$ ./mirror.sh update
[update] octocat/Hello-World.git
  remote   git@github.com:octocat/Hello-World.git
  head     master @ 7fd1a60
  refs     1 branches, 0 tags
  size     1.2M
  up to date
```

변경이 있으면 어떤 ref 가 어떻게 바뀌었는지 표시합니다.

```console
[update] example/demo-app.git
  ...
  changes  1 updated, 0 added, 0 deleted
  ~ refs/heads/main  1a2b3c4..5d6e7f8
```

### help

```console
$ ./mirror.sh help
```

## 백업 (원격이 삭제/덮어쓴 이력 보존)

원격에서 브랜치/태그가 삭제되거나 force-push 로 이력이 덮어써지면, 해당 ref 의 이전 tip 을 자동으로 백업합니다.

- 위치: `refs/mirror-backup/<UTC타임스탬프>/<원래 ref>`
  (예: `refs/mirror-backup/20260101T000000Z/heads/main`)
- fast-forward 업데이트나 새 브랜치/태그 추가는 백업하지 않습니다(이력이 그대로 살아있음).
- 백업 ref 는 mirror refspec 에서 제외(`^refs/mirror-backup/*`)되어 `--prune` 으로 삭제되지 않습니다.

```console
  backup   1 ref(s) preserved
  refs/heads/main  1a2b3c4 -> refs/mirror-backup/20260101T000000Z/heads/main
```

복구 예:

```console
$ git -C example/demo-app.git update-ref refs/heads/main \
    refs/mirror-backup/20260101T000000Z/heads/main
```
