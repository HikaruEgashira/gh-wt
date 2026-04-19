# gh-wt v0 設計書

## 概要

`gh wt add <branch>` で作成する worktree を **CoW overlay の shared reference + per-session upper** として実装する。Working tree の物理複製はなく、worktree 作成は数十ミリ秒、N session のディスク消費は `1 × repo_size + Σ session の差分` に収束する。

- **Phase 1 (Linux)**: OverlayFS をそのまま利用する。
- **Phase 2 (macOS)**: FSKit System Extension で OverlayFS と意味論的に等価な overlay を実装する。

旧版の Dependency Caching は overlay の lower 共有に包含されるため削除する。

---

## 設計原則

1. **単一経路**: 各プラットフォームで overlay 実装は1つ。フラグによる分岐を持たない。
2. **後方互換不要**: v0 なので旧挙動・旧コマンド・旧 feature との互換は考慮しない。
3. **Overlay が primary primitive**: ファイル共有・隔離・CoW の全てを overlay で一元化する。追加の symlink 層・cache 層を入れない。
4. **Git native 機構に乗る**: Session は `git worktree` の linked worktree として登録する。独自の `.git` 配線は避ける。
5. **プラットフォーム差は薄い抽象層で吸収**: Shell script 本体はプラットフォーム中立、overlay mount/umount のみを platform 別に実装する。

---

## アーキテクチャ

```
+- 原 repo ----------------------+
|  ~/src/myapp/                  |
|  |-- .git/                     |  <- 全 object の真源
|  |   \-- worktrees/            |  <- linked worktree metadata
|  |       \-- <sid>/            |
|  \-- ...                       |
+--------------------------------+
            ^ objects via git worktree mechanism
            |
+- gh-wt cache -----------------+
|  ~/.cache/gh-wt/<repo-id>/     |
|  |-- ref/<tree-sha>/           |  <- shared reference (immutable)
|  \-- sessions/<sid>/           |
|      |-- upper/                |  <- CoW 書き込み先
|      \-- workdir/              |  <- overlay 作業領域 (Linux only)
+--------------------------------+
            |
            v overlay mount (platform 固有)
+- ユーザ可視 ------------------+
|  <mountpoint>/                 |
|  |-- .git                      |  <- upper 上のファイル (gitdir: ...)
|  \-- <overlay view>            |  <- lower ∪ upper
+--------------------------------+
```

原 repo が object store、gh-wt cache が reference と session の物理領域、overlay mount がユーザ可視 worktree を合成する。**原 repo と gh-wt cache は独立**、object 共有は `git worktree` の linked mechanism が担う（alternates 不使用）。

Overlay 層のみ platform 別実装:
- **Linux**: カーネルの OverlayFS
- **macOS**: FSKit System Extension（Phase 2）

---

## データレイアウト

### Cache ルート

```
~/.cache/gh-wt/<repo-id>/
|-- ref/
|   \-- <tree-sha>/          # commit tree SHA で命名、immutable
\-- sessions/
    \-- <sid>/
        |-- upper/
        \-- workdir/          # Linux OverlayFS のみ使用
```

- `<repo-id>`: 原 repo の absolute path を SHA-1 した値
- `<sid>`: branch 名から derive、衝突時は suffix
- `<tree-sha>`: `git rev-parse <branch>^{tree}` の値

Reference を commit tree SHA で命名することで、同一 tree を持つ session は自動で同じ reference を共有する。Branch が進んでも古い reference は残る（古い session が生きている間）。

---

## Session ライフサイクル

### `gh wt add <branch> [path]`

1. 環境チェック: overlay 利用可能、cache dir 書き込み可能。NG なら即 error terminate。
2. Branch の commit tree SHA を取得: `git rev-parse <branch>^{tree}`
3. Reference 準備:
   - `<cache>/ref/<tree-sha>/` が無ければ作成:
     ```
     git archive <branch> | tar -x -C <ref-path>
     ```
     `.git` を持たない raw tree が展開される。作成後はこの dir を touch しない（規約上 immutable）。
4. Session dir 作成: `mkdir -p <cache>/sessions/<sid>/{upper,workdir}`
5. Mountpoint を空 dir として作成
6. `git worktree add --no-checkout <mountpoint> <branch>`
   - 原 repo の `.git/worktrees/<sid>/` に metadata が書かれる
   - `<mountpoint>/.git` file が作られ `gitdir: <main>/.git/worktrees/<sid>` を指す
7. 生成された `.git` file を upper に移動:
   ```
   mv <mountpoint>/.git <cache>/sessions/<sid>/upper/.git
   ```
8. Platform 固有の overlay mount を呼び出す（後述の abstraction 経由）
9. `git -C <mountpoint> update-index --refresh` で index を整合

Reference 未生成時は archive+tar で数秒（repo size 依存）。生成済みなら mount + index refresh で 50-100ms（Linux）、200-400ms 程度（macOS、FSKit userspace 越し）。

### `gh wt list`

`git worktree list` を呼び出して表示。全 session は linked worktree として登録されているので git native で列挙される。gh-wt 独自の session index は持たない。

### `gh wt remove`

1. fzf で worktree 選択
2. Mountpoint で動作中プロセスがないか確認（Linux は `fuser -m`、macOS は `lsof`）
3. Overlay umount（platform 固有）
4. `git worktree remove <mountpoint>`
5. `<cache>/sessions/<sid>/` を削除

Reference は消さない。削除は `gh wt gc` の責務。

### `gh wt gc`

未参照 reference = 現存する overlay の lower として使われていない reference。現役 overlay の lowerdir を列挙して突き合わせて削除する。

---

## Overlay 抽象

Platform 差は以下の薄い shell function に閉じ込める:

```bash
overlay_mount() {
  local lower=$1 upper=$2 workdir=$3 mountpoint=$4
  case "$(uname -s)" in
    Linux)
      mount -t overlay overlay \
        -o lowerdir="$lower",upperdir="$upper",workdir="$workdir" \
        "$mountpoint"
      ;;
    Darwin)
      gh-wt-mount-overlay \
        --lower "$lower" --upper "$upper" --mountpoint "$mountpoint"
      ;;
    *) err "unsupported platform" ;;
  esac
}

overlay_umount() {
  local mountpoint=$1
  case "$(uname -s)" in
    Linux)  umount "$mountpoint" ;;
    Darwin) gh-wt-mount-overlay --unmount "$mountpoint" ;;
    *) err "unsupported platform" ;;
  esac
}
```

この2関数以外は shell 本体で platform 中立。`gh-wt-mount-overlay` は macOS の FSKit extension にアクセスするヘルパバイナリ（後述）。

---

## コマンド仕様

v0 は以下6コマンド。フラグは持たない。

| コマンド | 機能 |
|---|---|
| `gh wt add <branch> [path]` | Overlay session を作成 |
| `gh wt list` | `git worktree list` のラッパ |
| `gh wt remove` | fzf 選択 + umount + worktree remove |
| `gh wt -- <cmd>` | fzf 選択 + session dir で `<cmd>` 実行 |
| `gh wt <cmd>` | fzf 選択 + path 引数として `<cmd>` 実行 |
| `gh wt gc` | 未参照 reference の削除 |

補助:

| コマンド | 機能 |
|---|---|
| `gh wt doctor` | overlay 利用可能性・環境チェック |

---

## Hard requirements

### Phase 1 (Linux)

起動時に検出、NG なら error terminate:

1. Linux kernel 5.11 以上
2. `/proc/filesystems` に `overlay` エントリ
3. 原 repo が通常の（non-bare）git repository
4. gh-wt プロセスが mount syscall を実行可能（root または `CAP_SYS_ADMIN` 相当）

### Phase 2 (macOS)

1. macOS 15 (Sequoia) 以上、ただし FSKit の成熟度から **macOS 26 以上を推奨サポート範囲**とする
2. gh-wt の FSKit extension がインストール済み、かつ System Settings > Login Items and Extensions > File System Extensions で有効化済み
3. 原 repo が通常の git repository

古い macOS、Windows、container 環境で overlay primitive 不在なケースはサポート外。

---

## Dependency Caching の削除

旧版の `Dependency Caching`（node_modules、.venv、target、vendor、.build、zig-cache、deno_dir 等を symlink する機能）は v0 では存在しない。

### 削除理由

1. **Overlay の lower が同じ役割を果たす**。Reference に何かが存在すれば全 session で自動共有される。追加の symlink 層は二重の間接参照を生む。
2. **Symlink と overlay の相互作用が非自明**。`readdir`・`stat` の結果、copy-up の trigger 条件が複合化し debug が困難。
3. **「sibling worktree 間だけ」の共有セマンティクスが overlay モデルに合わない**。Overlay は reference と session の関係を明示的に扱う。Sibling 間共有は reference 経由で自然に実現される。

### ユーザ体験への影響

- **Session 内で `npm install` したとき**: 依存は upper に書かれ、その session 専用（per-session isolation）
- **全 session で同じ node_modules を共有したい場合**: v0 非対応。v1 で `gh wt ref prepare <cmd>` を設計
- **Build artifact (target/ 等) の upper 肥大**: `CARGO_TARGET_DIR` 等の環境変数で scratch に逃がすことを README で推奨。gh-wt は自動配線しない

---

## Phase 2: macOS 対応

### 設計方針

OverlayFS と意味論的に等価な overlay filesystem を **FSKit System Extension** として実装する。Phase 1 の Linux 側コードは変更せず、`overlay_mount` / `overlay_umount` の Darwin 分岐と FSKit extension バイナリの追加で対応する。

**なぜ FSKit か**:
- macFUSE は kernel extension で signing の制約が重く、macOS 26 以降は FSKit backend に移行済み
- Fuse-T / macFUSE 経由で既存の FUSE overlay 実装を利用する手もあるが、2層の userspace 層（FSKit → FUSE → 独自実装）を挟むことになり、性能劣化と debug 困難さが増す
- Apple 公式の userspace filesystem API で、今後の macOS で安定的にサポートされる

### コンポーネント構成

```
gh-wt (shell script, platform 中立)
    \-- overlay_mount / overlay_umount
         \-- [Darwin] gh-wt-mount-overlay (Swift ヘルパ CLI)
              \-- XPC 経由
                   \-- gh-wt-overlay.fskit (FSKit System Extension, Swift)
                        \-- Rust core (任意、FFI で)
                             \-- FsCore: lower と upper のマージロジック
```

FSKit extension 本体は Swift で `FSUnaryFileSystemOperations` を実装し、overlay の判定ロジック（lower vs upper の優先順位、whiteout、copy-up）は共通 core として Rust で書いて Swift から FFI で呼ぶ。

v0 Phase 2 の初期実装では Rust core を持たず、Swift 単体で書いても良い（コード量が200行規模に収まるなら）。

### Overlay の semantics 実装

FSKit extension は mount 時に lower と upper の2つの実 dir path を受け取り、以下のロジックで合成 view を提供する:

- **lookupItem / getItemAttributes**: upper に存在すれば upper を返す。Whiteout マーカーがあれば「存在しない」を返す。どちらでもなければ lower を返す。lower にも無ければ ENOENT。
- **enumerateDirectory**: upper の entry と lower の entry をマージ。重複は upper 優先、upper の whiteout エントリが指す名前は除外。
- **readFile**: lookupItem と同じ優先順位で実 file を open し read。
- **writeFile**:
  - upper に既にあれば upper に書く
  - upper に無く lower にあれば copy-up（lower → upper へ丸コピー）した後 upper に書く
  - どちらにも無ければ upper に新規作成
- **removeItem**:
  - upper にあれば削除
  - lower にあれば upper に whiteout marker を作成
- **renameItem**: 上記の組み合わせ。場合分けが多いので実装時に丁寧に testing する
- **createItem** (mkdir, create file): upper に作成、もし lower に同名の「削除マーカー」があれば先にクリア

### Whiteout の表現

OverlayFS は character device (0/0) を whiteout に使うが、FSKit 内部では任意の表現で良い（upper は外部から見えないので）。以下から選ぶ:

1. **xattr**: `<upper>/path/to/file` に `com.github.gh-wt.whiteout = 1` の xattr を立てる
2. **sidecar file**: `<upper>/path/.gh-wt-whiteout` のような sentinel
3. **ファイル名 prefix**: `<upper>/path/.whiteout-<name>`

**v0 Phase 2 案**: xattr 方式。APFS は xattr を efficient に扱い、通常の file オペレーションと分離して管理できる。

### Mount lifecycle (macOS)

1. **初回セットアップ（ユーザが1回だけ実行）**:
   - `gh-wt-overlay.app` をインストール（.dmg または `brew install gh-wt-overlay`）
   - System Settings > Login Items and Extensions > File System Extensions で「gh-wt-overlay」を有効化
   - `gh wt doctor` で extension が有効かを確認
2. **`gh wt add <branch>` 実行時**:
   - Shell が `gh-wt-mount-overlay --lower ... --upper ... --mountpoint ...` を起動
   - ヘルパ CLI が XPC で FSKit extension に mount 要求を送信
   - FSKit extension が <mountpoint> に overlay を mount
3. **`gh wt remove` 実行時**:
   - ヘルパ CLI が umount 要求を FSKit extension に送信
   - Extension が overlay を unmount

### 既知の制約

1. **Extension の有効化がユーザ単位**
2. **Kernel caching の欠如**: FSKit は FUSE の `entry_timeout` / `attr_timeout` 相当を持たない
3. **Userspace 越しのオーバーヘッド**: 1 op あたり 100μs 規模
4. **Signing と distribution**: Developer ID 署名 + notarization が必須
5. **macOS バージョン**: 26 以上推奨

### Distribution

v0 Phase 2 は `gh extension install` の shell script 配布では完結しない。

**v0 Phase 2 案**: gh-extension-precompile パターンに沿って Swift binary を同梱し、FSKit extension 本体（System Extension）は app bundle か Installer package で別配布。

### テスト戦略

Linux OverlayFS を ground truth として、FSKit 実装の挙動を照合する integration test suite を用意する。

---

## 技術的留意点（Phase 1 共通）

### Git の stat 信頼

Overlay の file は lower から upper に copy-up されると inode が変わる。Git が誤判定しないよう、session 作成時に linked worktree の config に書き込む:

```
[core]
    checkStat = minimal
    trustctime = false
```

macOS FSKit 実装でも inode の同一性は保証しない（lower と upper で別 inode）ので同じ設定が必要。

### Reference の immutability

Reference dir は chmod による write 禁止は行わない。規約で「gh-wt 以外は reference を触らない」を徹底する。

### 原 repo の git gc

Linked worktree として registered されている branch の commit は git gc から protected される。Reference の中身は git 管理外なので GC 影響を受けない。

### Submodule

Submodule を持つ repo は v0 サポート外。`gh wt add` 時に `.gitmodules` の存在を検出して error terminate する。

---

## 開いている判断

1. **Reference 作成方法**: `git archive | tar` vs `git checkout-index --prefix=<ref>/ -a`. Bench して decide。
2. **Mountpoint path convention**: default を「原 repo の parent に branch 名」とするが、parent が書き込み不可・branch 名が `/` を含む等の corner case 処理を決める。
3. **GC の発動タイミング**: 手動のみ vs `gh wt add` 時に lazy 実行。v0 は手動のみ。
4. **Phase 2 Swift core vs Rust core**: v0 Phase 2 の初期は Swift 単体推奨。
5. **Phase 2 whiteout 表現**: v0 Phase 2 は xattr 決め打ち。

---

## 段階的実装

### Phase 1 (Linux) — v0 最初のリリース

1. **Spike**: 手動 shell で overlay mount + `git worktree add --no-checkout` + `.git` 移動 + index 整合が動くこと
2. **Core**: `add` / `remove` / `list` を実装
3. **Ergonomics**: `gh wt -- <cmd>` と `gh wt <cmd>`
4. **Cleanup**: `gh wt gc`
5. **Polish**: Error messages、README、`gh wt doctor`

### Phase 2 (macOS) — v0 の次のリリース

1. FSKit extension の骨格
2. Overlay semantics の実装
3. mount/umount helper CLI
4. Shell 統合
5. Integration test
6. Distribution
7. Docs

### v1 で検討

- `gh wt ref prepare <cmd>`
- Submodule 対応
- Reference の branch 進行への追従
- User namespace mode (Linux、sudo 不要化)
- Per-repo mount namespace による大規模 scale

---

## 破棄した設計要素

- **`--overlay` / `--no-overlay` フラグ**
- **`git worktree add` への fallback**
- **macOS で macFUSE / Fuse-T 経由の FUSE overlay 実装**
- **Dependency Caching (symlink)**
- **Session の独自 index**
- **Alternates による object 共有**
- **Branch 単位の reference**
- **Reference refresh / update**
