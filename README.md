# wp-sync

WordPress の `local` と `prod` 環境を同期するための Bash スクリプト集です。

- DB 同期: `wp db export/import` + `wp search-replace`
- ファイル同期: `rsync --delete`（`theme / plugins / uploads / wp-content`）
- 本番書き込み時は確認プロンプトあり
- `DRY_RUN=1` でファイル同期のみ事前確認可能

## 特徴

- `make` で短いコマンドを提供
- SSH 設定は通常 `~/.ssh/config` を利用（必要時のみ上書き）
- rsync のバックアップ世代管理（既定で有効）
- `.rsyncignore` でキャッシュ・バックアップ系を除外

## 前提条件

以下コマンドが使えること:

- `bash` (4+ 推奨)
- `make`
- `ssh`
- `rsync`
- `wp` (WP-CLI, ローカル側で必須)

リモート側（`prod`）でも `wp` が実行できる必要があります。

## セットアップ

1. 各 WordPress サイトのルートにこのリポジトリを `wp-sync` として配置

```bash
cd /path/to/wordpress-root
git clone <your-repo-url> wp-sync
cd wp-sync
```

2. 環境ファイルを作成

```bash
cp .env.sync.example .env.sync
```

3. `.env.sync` を編集

- `PROD_HOST`, `PROD_PATH`, `PROD_URL`
- `LOCAL_PATH`, `LOCAL_URL`
- 必要なら `SSH_KEY`, `SSH_PORT`, `BACKUP_*`

## 使い方

`wp-sync` ディレクトリで実行します。

```bash
make pull-d   # prod -> local DB
make push-d   # local -> prod DB

make pull-t   # prod -> local theme
make push-t   # local -> prod theme

make pull-p   # prod -> local plugins
make push-p   # local -> prod plugins

make pull-u   # prod -> local uploads
make push-u   # local -> prod uploads

make pull-a   # prod -> local all (db + wp-content)
make push-a   # local -> prod all (db + wp-content)
```

エイリアス:

```bash
make pull-db
make push-all
```

## ドライラン

ファイル同期のみ `--dry-run` で確認できます（DB 同期は実行されます）。

```bash
DRY_RUN=1 make pull-a
DRY_RUN=1 make push-t
```

## 安全運用の注意

- `push-*`（`local -> prod`）は本番へ書き込むため、必ず確認してから実行してください。
- `all` は `DB -> files` の順で実行されます。
- `BACKUP_DIR_PROD` は可能な限り非公開ディレクトリを指定してください。
- `rsync --delete` を使うため、同期先にのみ存在するファイルは削除されます。

## 除外設定

`.rsyncignore` で除外対象を管理します。

- `cache` などの一時ファイル
- `updraft`, `ai1wm-backups`, `wpvividbackups` などのバックアップ系

環境ごとに調整したい場合は `.rsyncignore` を編集してください。

## トラブルシュート

- `.env.sync not found`: `.env.sync.example` からコピーしてください。
- `wp command is not available`: ローカルの `wp` パスを確認してください。
- SSH 接続失敗: `PROD_HOST` と `~/.ssh/config`、または `SSH_KEY` / `SSH_PORT` を見直してください。
- URL 置換が不十分: `.env.sync` の `*_URL` が実サイト URL と一致しているか確認してください。

## 開発メモ

- スクリプト本体: `sync.sh`
- タスク定義: `Makefile`
- 機密値は `.env.sync` に置き、Git 管理しない（`.gitignore` 済み）
