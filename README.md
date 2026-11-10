# chrome-cdp

WSL2 で動かす [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) から、Windows の Chrome を
[chrome-devtools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) で操作するための skill。
Claude は、ユーザーが見ているのと同じ Chrome のウィンドウを操作する。開発中の画面の表示・動作の確認、
スクリーンショット、コンソールエラーや通信、DevTools で選んだ要素、パフォーマンスの調査などを、
別のヘッドレスブラウザを立てずに行える。

ssh で WSL にログインして使うときは、手元の端末の Chrome を `ssh -R` で WSL に転送し、そちらを操作する。

SKILL.md、スクリプトのメッセージとコメントは日本語で書いている。

設定は、WSL の Claude Code に次のように頼めばよい([インストール](#インストール))。

```text
https://github.com/izumo-m/chrome-cdp これ設定しといて
```

## できること

- Windows の Chrome を CDP 付き(`--remote-debugging-port=9222`、普段使いとは別のプロファイル、拡張機能なし)で
  起動し、`Browser.close` で正常に終了させる。
- WSL が NAT のとき、Windows の 127.0.0.1 でしか待ち受けない CDP に WSL から届くよう、Windows 側に
  TCP リレー(PowerShell)を立てる。WSL が mirrored のときは自動で判定してリレーを立てない(mirrored は未検証)。
- skill を読み込んだときに、リレー・Chrome・ssh の転送・このセッションの MCP の接続先を調べて Claude に渡す。
  Claude はそれを見て、Chrome を起動する、ユーザーに Chrome を閉じてもらう、`/mcp` で再接続してもらう、などを判断する。
- Chrome が起動していないとき、Claude は起動してよいかをユーザーに確認してから起動する(「Chrome 開いて」と
  頼んだときを除く)。停止は頼まれたときだけ行う。

## 仕組み

WSL が NAT のとき(WSL の既定):

```text
WSL2                                     Windows
  chrome-devtools MCP ──> <ゲートウェイ IP>:9222 ──[cdp-relay.ps1]──> 127.0.0.1:9222  Chrome
```

WSL が mirrored のとき(127.0.0.1 を Windows と共有。未検証):

```text
WSL2 / Windows
  chrome-devtools MCP ──> 127.0.0.1:9222  Chrome
```

ssh でログインしてきたとき(手元の端末の Chrome を使う):

```text
手元の端末                                          WSL2
  Chrome 127.0.0.1:9222 <── ssh -R 9222:127.0.0.1:9222 ── 127.0.0.1:9222 <── chrome-devtools MCP
```

MCP は起動したとき(セッションの開始・resume、`/mcp` での再接続)に接続先を 1 回だけ決める。
WSL が mirrored なら常に 127.0.0.1:9222 に繋ぐ。NAT なら、WSL の :9222 で何かが待ち受けていれば(普通は ssh の転送)
WSL の 127.0.0.1:9222 に、いなければゲートウェイ IP:9222 に繋ぐ。

## 動作環境

- Windows 10 / 11 と WSL2(ネットワークモードは NAT。WSL の既定)
  - mirrored モードにも対応するコードはあるが、動作は確かめていない。試した結果は issue で知らせてもらえると助かる。
  - WSL の interop が有効なこと(WSL から `cmd.exe`、`netstat.exe`、`powershell.exe`、`curl.exe` を実行する)
- Windows の Google Chrome
  - 既定では `C:\Program Files\Google\Chrome\Application\chrome.exe` を使う。別の場所なら `CHROME_CDP_EXE` を設定する。
- WSL 側のコマンド: bash、curl、iproute2(`ip`、`ss`)、util-linux(`setsid`)、`iconv`、`base64`
- Node.js 22.12 以上(stop と、`npx` で動かす chrome-devtools-mcp が使う)
- Claude Code

## インストール

WSL の Claude Code に次のように頼めば、下の「設定の手順」に沿って設定してくれる。

```text
https://github.com/izumo-m/chrome-cdp これ設定しといて
```

途中でコマンドの実行の許可を求められるので、内容を確かめて許可する。手で設定するときも同じ手順で行う。

### 設定の手順

Claude Code はこの手順に従って設定する。手順 2 の後は、GitHub のページ(WebFetch の要約)ではなく、
clone した `~/.claude/skills/chrome-cdp/README.md` のこの節を読み直してから続ける。要約ではコマンドが崩れることがある。

設定の途中で Chrome は起動しない(`chrome-cdp.sh start` は実行しない)。ユーザーの画面にウィンドウが開くため。
`CLAUDE_CONFIG_DIR` を設定している環境では、以下の `~/.claude` をその値に読み替える。

1. 動作環境を確かめる。満たさないものがあれば、そこで止めてユーザーに伝える。Node.js や Chrome を
   勝手にインストールしない。

   ```bash
   uname -r                                               # microsoft-standard-WSL2 などを含む(WSL2 である)
   (cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c ver)  # Windows のバージョンが出る(WSL の interop が有効)
   node --version                                         # v22.12 以上
   command -v git npx curl ip ss setsid iconv base64 claude   # すべて見つかる
   ls "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"   # Windows の Chrome(既定の場所)
   ```

   Chrome が既定の場所に無ければ、次の 2 か所を探す。見つかれば手順 4 で `CHROME_CDP_EXE` に設定する。
   どこにも無ければ止める。

   ```bash
   ls "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
   ls "$(wslpath -u "$(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c 'echo %LOCALAPPDATA%' | tr -d '\r')")/Google/Chrome/Application/chrome.exe"   # ユーザーごとのインストール
   ```

2. skill のディレクトリに clone する。

   ```bash
   git clone https://github.com/izumo-m/chrome-cdp.git ~/.claude/skills/chrome-cdp
   ```

   `~/.claude/skills/chrome-cdp` が既にあるときは clone しない。

   - `~/.claude/skills/chrome-cdp/.git` があり、`git -C ~/.claude/skills/chrome-cdp remote get-url origin` が
     このリポジトリ(`https://github.com/izumo-m/chrome-cdp.git` や `git@github.com:izumo-m/chrome-cdp.git`)なら、
     `git -C ~/.claude/skills/chrome-cdp pull --ff-only` で更新して続ける。
   - そうでなければ上書きせず、置き換えてよいかユーザーに聞く。置き換えるなら、既存のディレクトリを
     `~/.claude/skills` の外に移してから clone する(`~/.claude/skills` の下に残すと、同じ名前の skill が
     2 つ読み込まれる)。置き換えないなら、設定をやめる。

3. MCP サーバーを `chrome-devtools` という名前で user スコープに登録する。SKILL.md は `mcp__chrome-devtools__*`
   というツール名と、この名前での `/mcp` の再接続を前提にしている。まず登録済みかを確かめる。

   ```bash
   claude mcp get chrome-devtools
   ```

   - 未登録(終了コード 1、`No MCP server named "chrome-devtools"`)なら登録する。

     ```bash
     claude mcp add-json chrome-devtools --scope user '{"type":"stdio","command":"bash","args":["-c","if wslinfo --networking-mode 2>/dev/null | grep -q mirrored || ss -ltnH sport = :9222 | grep -q .; then h=127.0.0.1; else read -r _ _ h _ < <(ip route show default); fi; exec npx -y chrome-devtools-mcp@latest --browser-url=http://$h:9222 --no-usage-statistics"]}'
     ```

   - 登録済みで、`Scope:` が user(`User config`)、`Args:` が上の登録コマンドの `-c` の後と同じなら、そのままにする。
   - 登録済みでそれ以外なら、置き換えてよいかユーザーに聞く。置き換えるなら、`Scope:` に出た scope
     (user / project / local)で `claude mcp remove chrome-devtools -s <scope>` してから登録する。

   登録したコマンドは、MCP の起動時に、WSL が mirrored か WSL の :9222 で何かが待ち受けていれば 127.0.0.1、
   いなければデフォルトゲートウェイ IP に繋ぐ。`--no-usage-statistics` は chrome-devtools-mcp の利用統計の送信を止める。

4. 必要なときだけ環境変数を設定する(普通は要らない)。

   - Chrome が既定の場所に無い(手順 1): `CHROME_CDP_EXE` に chrome.exe の WSL のパスを設定する。
   - ユーザーがプロファイルの場所を指定した: `CHROME_CDP_USER_DATA_DIR` に Windows のパスを設定する。

   `~/.claude/settings.json` の `env` に足す。既存の内容は消さない。

   ```json
   {
     "env": {
       "CHROME_CDP_EXE": "/mnt/c/Users/me/AppData/Local/Google/Chrome/Application/chrome.exe"
     }
   }
   ```

5. 状態を表示して、WSL から Windows 側を調べられることを確かめる。

   ```bash
   ~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh status
   ```

   `relay:` と `chrome:` の行が出れば準備できている。`error:` が出たら、その内容をユーザーに伝える。
   `mcp:` の行は、この時点では `?` でよい(MCP は Claude Code を起動し直すと動く)。

6. ユーザーに次のことを伝えて終える。

   - Claude Code を起動し直すと使える(MCP サーバーと skill は起動時に読み込まれる)。
   - 初めてブラウザを使う依頼をしたとき、Chrome を起動してよいか聞かれる。WSL が NAT なら、初回に
     ファイアウォールの警告が出ることがある([初回のファイアウォールの警告](#初回のファイアウォールの警告))。
   - Chrome は専用のプロファイルで開くので、個人のアカウントではログインしない(CDP には認証が無い)。

### 更新

```bash
git -C ~/.claude/skills/chrome-cdp pull --ff-only
```

MCP の登録を変える必要があるときは [CHANGELOG.md](CHANGELOG.md) に書く。

### アンインストール

```bash
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh stop   # Chrome が動いていれば閉じ、リレーを止める
claude mcp remove chrome-devtools -s user
rm -rf ~/.claude/skills/chrome-cdp
```

Windows 側には `%USERPROFILE%\.cache\chrome-cdp` が残る(既定の Chrome のプロファイル `profile` と、
リレーのコピー)。要らなければ削除する。

## 使い方

Claude に頼むだけでよい。Chrome と言わなくても、ブラウザで画面を見る・操作する依頼なら skill が読み込まれる。

- 「localhost:3000 を開いてスクリーンショットを撮って」
- 「この画面のコンソールエラーを見て」
- 「DevTools で選んだ要素の CSS を調べて」
- 「スマホ幅で表示を確認して」
- 「Chrome を止めて」

初めて使うときは、Chrome を起動してよいか聞かれる。許可すると Windows の画面に専用プロファイルの Chrome が開く。

### 初回のファイアウォールの警告

WSL が NAT のとき、初めてリレーを立てると、Windows Defender ファイアウォールが Windows PowerShell の受信を
許可するか尋ねることがある。許可しないと WSL からリレーに届かず、start は「CDP に応答しない」で止まる。
WSL の仮想ネットワークは多くの環境で「パブリック ネットワーク」として扱われる。リレーが待ち受けるのは
WSL のゲートウェイ IP(Windows 側の WSL 用の仮想アダプター)だけで、LAN 側では待ち受けない。

### ssh でログインして使う

手元の端末(GUI のあるマシン)の Chrome を、ログイン先の WSL の Claude Code から操作する。

1. 手元で Chrome を CDP 付きで起動する(`chrome` は手元の OS での Chrome の実行ファイル)。プロファイルは
   普段使いと別のものにする(Chrome 136 以降は、既定のプロファイルでは `--remote-debugging-port` が無視される)。

   ```bash
   chrome --remote-debugging-port=9222 --user-data-dir=<普段と別のディレクトリ>
   ```

   手元が Windows で、そこにもこの skill があるなら、Claude に「Chrome だけ起動して」と頼むか、
   `scripts/chrome-cdp.sh start --no-relay` を実行してもよい。

2. ポートを転送してログインし、Claude Code を起動する。

   ```bash
   ssh -R 9222:127.0.0.1:9222 <WSL のホスト>
   ```

3. MCP は起動時に WSL の :9222 の待ち受けを見つけて、手元の Chrome に繋ぐ。Claude Code を起動した後で
   転送を張った・切ったときは、`/mcp` で chrome-devtools を再接続する(Claude もそう案内する)。

WSL が NAT で localhost の転送が有効(既定)なら、転送している間は Windows 側の 127.0.0.1:9222 を `wslrelay.exe` が
使うので、その Windows で CDP 付きの Chrome を同時には起動できない。

### スクリプトを直接使う

```bash
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh status            # 状態を表示する
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh start             # リレーと Chrome を起動する(起動済みの部分は何もしない)
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh start --no-relay  # Chrome だけ起動する(ssh の転送用)
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh stop              # Chrome を正常終了させ、リレーを止める
~/.claude/skills/chrome-cdp/scripts/chrome-cdp.sh --help            # 使い方・環境変数の今の値・終了コードを表示する
```

status の各行:

| 行 | 内容 |
| --- | --- |
| `host ip:` / `network:` | WSL のゲートウェイ IP。mirrored なら `network: mirrored` |
| `ssh-tunnel:` | WSL の :9222 で待ち受けているのが ssh の転送か、その先が CDP に応答するか |
| `mcp:` | このセッションの MCP の接続先。Claude Code の外から実行すると `?` になる |
| `relay:` | リレーが動いているか |
| `chrome:` | Chrome のバージョン、または起動していない・別のプロセスが 9222 を使っている、など |

同じプロファイルの Chrome が CDP なしで動いている、9222 を Chrome 以外が使っている、などのときは、start は
何も起動せずにその旨を出して止まる。stop も、9222 を使っているのが設定したプロファイルの Chrome でなければ閉じない。

## 環境変数

| 変数 | 既定値 | 内容 |
| --- | --- | --- |
| `CHROME_CDP_USER_DATA_DIR` | `%USERPROFILE%\.cache\chrome-cdp\profile` | Chrome のプロファイル(Windows のパス)。普段使いとは別の、ほかのユーザーが読み書きできない場所にする |
| `CHROME_CDP_EXE` | `/mnt/c/Program Files/Google/Chrome/Application/chrome.exe` | chrome.exe(WSL のパス) |
| `CHROME_CDP_PORT` | `9222` | CDP のポート。変えるなら MCP の登録コマンドの 9222 も変える(SKILL.md の説明は 9222 のまま) |

Claude Code から使うときは、`~/.claude/settings.json` の `env` に書くと、skill が実行するスクリプトに渡る。

```json
{
  "env": {
    "CHROME_CDP_USER_DATA_DIR": "C:\\temp\\my-cdp-profile"
  }
}
```

## セキュリティ

- CDP には認証が無い。Chrome が CDP 付きで動いている間は、WSL 内のプロセスを含め、同じマシンのプロセスは誰でも
  その Chrome を操作でき、Cookie なども読める。ログアウトせずにユーザーを切り替えたときの、ほかのユーザーの
  プロセスも含む。専用のプロファイルを使い、個人のアカウントではログインしない。使い終わったら stop する。
- 既定のプロファイルは、本人しか読み書きできない `%USERPROFILE%\.cache\chrome-cdp\profile` に置く。
  `C:\temp` などの下は、そのマシンにログインできる全員が読み書きできる(`Authenticated Users` に変更の権限がある)
  ので、ほかのユーザーにプロファイル(履歴など)を読まれたり、書き換えられたりする。
  `CHROME_CDP_USER_DATA_DIR` を設定するときも、そういう場所は避ける。
- リレーは WSL のゲートウェイ IP でだけ待ち受け、127.0.0.1:9222 にだけ中継する。
- リレーは `%USERPROFILE%\.cache\chrome-cdp\cdp-relay.ps1` にコピーし、`-ExecutionPolicy Bypass` で実行する。
  ログは WSL の `/tmp/chrome-cdp-relay.log`。
- Chrome は拡張機能を無効にして起動する(拡張機能の content script が画面の書き換えに反応して、
  操作のたびに数秒固まったことがあるため)。

脆弱性の報告については [SECURITY.md](SECURITY.md) を見てほしい。

## ファイル

| ファイル | 内容 |
| --- | --- |
| `SKILL.md` | skill 本体。Claude が読む手順 |
| `scripts/chrome-cdp.sh` | 起動・停止・状態の表示(WSL 側) |
| `scripts/cdp-relay.ps1` | TCP リレー(Windows 側)。Windows PowerShell 5.1 が BOM なしのファイルを ANSI で読むので、ASCII だけで書く |

## ライセンス

[MIT](LICENSE)
