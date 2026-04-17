# Changelog

このファイルでは、このプロジェクトの主な変更を記録します。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) を参考にし、
バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) を前提にします。

## [Unreleased]

### Added
- `LICENSE` を追加し、MIT License を明示。
- 公開向けの `README.md` を整備（前提条件、セットアップ、運用注意、トラブルシュート）。
- `.env.sync.example` を公開向けに汎用化。
- `sync.sh` にコメント追加と必須コマンド（`ssh`, `rsync`）の事前チェックを追加。

### Changed
- README の構成を再編成し、使用手順と安全上の注意を明確化。
- `.env.sync.example` 内のバックアップディレクトリ注釈表現を修正。

