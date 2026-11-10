# 変更履歴

このプロジェクトの主な変更をここに記録する。

形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に基づく。

## [Unreleased]

最初の公開版。WSL の NAT モード(既定)で動作を確かめている。mirrored モードは未検証。

### 修正

- status がリレーや Chrome を時々「動いていない」と表示し、start・stop もそれに従って誤ることがあった。
  Windows によっては TCP の一覧(netstat.exe)から待ち受けの行が抜けるため。リレーと Chrome が動いているかを、
  Windows のプロセスのコマンドラインで判定するようにした。

### セキュリティ

- 既定のプロファイルを `C:\temp\chrome-cdp-profile` から `%USERPROFILE%\.cache\chrome-cdp\profile` に変えた。
  `C:\temp` の下は、そのマシンにログインできる全員が読み書きできるため。リレーのコピーも
  `%LOCALAPPDATA%\chrome-cdp` から `%USERPROFILE%\.cache\chrome-cdp` に移した。前の場所はもう使わないので、
  要らなければ削除する。

### 変更

- stop は、CDP で応答した Chrome 本体のプロセス ID が、設定したプロファイルの Chrome と一致するときだけ閉じる。
- 9222 を別のプロファイルの Chrome が使っているとき、そのプロファイルを表示する。
- start が Chrome を起動するとき、実行するコマンドを表示する。
- `--help` で、使い方、環境変数の今の値、終了コード、更新方法を表示する。

[Unreleased]: https://github.com/izumo-m/chrome-cdp/commits/main
