---
name: chrome-cdp
description: Web アプリの画面をブラウザで見る・操作する・調べるときは、Chrome と言われなくても最初に読む。開発中の画面(localhost の dev サーバーなど)の表示・動作確認、スクリーンショット、コンソールエラーや通信、DevTools で選んだ要素、スマホ幅・ダークモード、表示の遅さ(パフォーマンス・Lighthouse)の調査など。直した変更を実画面で確かめるときも、ヘッドレスブラウザ等を別に立てずにこれを使う。ユーザーと共有している Chrome(この Windows のもの、または ssh で転送された手元の端末のもの)を chrome-devtools MCP で操作するので、mcp__chrome-devtools__* を使う前や接続エラー時に読む。Chrome の起動・停止もこれ。e2e テストの実行や URL の本文取得には使わない。
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh *)
---

# chrome-cdp

Windows の chrome.exe を CDP 付きで起動し、Windows 側の PowerShell リレー経由で NAT の WSL2 から
MCP サーバー `chrome-devtools` が繋ぐ。ユーザーは同じ Chrome のウィンドウを見て操作している。
ユーザーが ssh でログインしてきているときは、手元の端末の Chrome が ssh で WSL に転送されていて、
同じ MCP がそちらに繋ぐ(次の「どの Chrome に繋がっているか」)。

この skill を読み込んだ時点の状態:

!`${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh status 2>&1 || true`

## どの Chrome に繋がっているか

MCP `chrome-devtools` は、起動したとき(セッションの開始・resume、`/mcp` での再接続)に接続先を 1 回だけ決める。
WSL の :9222 で何かが待ち受けていれば WSL の 127.0.0.1:9222、いなければリレー(ゲートウェイ IP:9222)に繋ぐ
(WSL が mirrored なら常に 127.0.0.1:9222)。
WSL の :9222 で待ち受けているのは普通、`ssh -R 9222:127.0.0.1:9222` で転送された手元の端末の Chrome。
このセッションの MCP の実際の接続先は `mcp:` 行に出る。

- `mcp:` 行に `今の状態とずれている` が付いている: MCP の起動後に転送を張った・切った。ツールは使わず、
  ユーザーに `/mcp` で chrome-devtools を再接続してもらう(自分ではできない)。再接続されたら status を取り直す。
- `mcp: http://127.0.0.1:9222`: `ssh-tunnel:` 行を見る。
  - `yes`: ユーザーは ssh でログインしてきていて、手元の端末の Chrome に繋がっている。この Windows の Chrome と
    リレーには触らない(下の start / stop はしない)。`relay:` / `chrome:` 行や `error:` は Windows 側のことなので
    気にしなくてよい(`chrome:` 行の「Chrome 以外が使っている(wslrelay.exe …)」は転送のせい)。
    括弧内が `転送の先が CDP に応答しない` なら、または繋がらなければ、手元で Chrome が CDP 付き
    (`--remote-debugging-port=9222` と普段と別の `--user-data-dir`)で動いているかをユーザーに確かめてもらう。
    手元の Chrome の起動・終了はユーザーが行う。
  - `no (WSL の :9222 を … が待ち受けている)`: 転送ではないものが WSL の 9222 を使っていて、MCP はそれに繋いでいる
    (このとき Windows 側の 127.0.0.1:9222 も wslrelay.exe に取られる)。ツールは使わず、括弧内をユーザーに伝える。
- `mcp: http://<ゲートウェイ IP>:9222 (リレー経由でこの Windows の Chrome)`: 下の「この Windows の Chrome を使う」。
  ただし、ユーザーがリモートで作業していて Windows の画面が見えないと分かっているなら、start せずに、
  手元で Chrome を CDP 付きで起動して `ssh -R 9222:127.0.0.1:9222` 付きで繋ぎ直してもらう。
  繋ぎ直した後、resume か `/mcp` での再接続で MCP の接続先が手元の Chrome に切り替わる。
- それ以外(`mcp: ?`、`ssh-tunnel: ?` など): 判定できていない。status を取り直し、変わらなければ括弧内を伝えて
  ユーザーにどちらの Chrome か聞く。

status は読み込んだ時点のもの。start / stop の前、resume した後、転送を張った・切ったと言われたとき、
繋がらなくなったときは status を取り直す。resume の前後で転送の有無が変わっていれば、接続先の Chrome も変わっている。

## この Windows の Chrome を使う

ブラウザを使う依頼では、この状態を見て次のように進める。

- 次のときは start しない(しても起動せずに止まる)。
  - `CDP なしで起動している`: 同じプロファイル(メッセージに出るパス)の Chrome が CDP なしで動いている。
    ユーザーに「閉じてもらえれば CDP 付きで開き直す」と伝え、閉じたと言われたら start する。
  - `待ち受けずに残っている`: 同じプロファイルの Chrome のプロセスが、9222 で待ち受けずに残っている
    (閉じた後の終了処理が長引いている、別のポートで CDP 付きで起動している、など)。status を取り直し、
    変わらなければ win pid をユーザーに伝えて終了させてもらう。
  - `Chrome 以外が使っている`: Windows の 127.0.0.1:9222 を別のプロセス(別プロファイルの Chrome を含む)が
    使っている。メッセージをユーザーに伝える。`wslrelay.exe` のときは WSL 内のプロセスが 9222 で待ち受けて
    いるので、`ssh-tunnel:` 行の括弧内(相手のプロセス)も合わせて伝える。
  - `error:` が出ている: そのメッセージをユーザーに伝える。
- 停止の依頼なら start せずに下の「停止」へ進む。
- それ以外で、`relay: stopped` か、`chrome:` 行がバージョン表記でない(`not running` など)なら
  `${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh start` を実行する(起動済みの部分は何もしない)。
  - `chrome: not running` のときは、start する前に「Chrome を起動してよいか」をユーザーに確認する。
    start はユーザーの画面に Chrome のウィンドウを開くので、ユーザーは勝手に開くのを望んでいない。
    ユーザーが「Chrome 開いて」「起動して」と明示的に頼んだときは確認不要。
  - `chrome: running (...リレーが無いので...)` なら、start はリレー(画面に出ない)を立てるだけなので確認不要。

`start` が失敗したら:

- `CDP なしで起動している` / `待ち受けずに残っている` / `Chrome 以外が使っている`: 上と同じ
  (status の後で状況が変わった)。同じプロファイルの Chrome が残っていると、start は 15 秒待って
  消えなければ止まる。
- `CDP に応答しない`: リレーか Chrome が固まっているなら、`stop` → `start` で直る。stop は Chrome を
  閉じるので、ユーザーに確認してから行う。stop → start しても同じなら、表示された win pid をユーザーに伝える。
- それ以外: メッセージに従う。リレーのログは `/tmp/chrome-cdp-relay.log`。

## ツールの使い方

- ページを対象にするツールは `pageId` が必須。最初に `list_pages` で ID を得る。
- `stop` → `start` で Chrome を起動し直すと、MCP は自動で再接続するがページ ID が変わる。
  `list_pages` を取り直す。MCP が起動し直したとき(resume、`/mcp` での再接続)も、履歴にあるページ ID は
  当てにならないので取り直す。
- ユーザーと同じ画面を使っている。遷移・クリック・入力など画面を変える操作は頼まれた範囲に留め、
  ユーザーが見ているタブを勝手に閉じない。
- 要素の特定は `take_snapshot`(uid が付く)。スクリーンショットより軽いので、まずこちらを使う。
- DevTools の Elements パネルで選択中の要素は、`take_snapshot` の結果に
  `[selected in the DevTools Elements panel]` と印が付く。選択の変更は通知されないので、
  「これ」「選んだ要素」と言われたらその都度取り直す。
- コンソール: `list_console_messages` で取れるのは、MCP が Chrome に接続した後の `console.*` 出力と
  ページのエラー・警告で、既定では最後のページ遷移以降の分だけ。`includePreservedMessages: true` で
  直近 3 回の遷移分まで遡れる。ユーザーが DevTools コンソールに直接打った式とその結果は取れない
  (`console.log(...)` で出してもらえば取れる)。ページ上の値は `evaluate_script` で自分で読める。
- DevTools をウィンドウ内にドッキングしていると、スクリーンショットのビューポートがその分狭い。

## 停止

`${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh stop` で Chrome を `Browser.close` で正常終了させ、リレーを止める。
リレーが止まっていても、閉じる間だけ立てて閉じる。閉じられなかったときは終了コード 1。
127.0.0.1:9222 を Chrome 以外が使っているときと、同じプロファイルの Chrome が CDP なしで動いている・
待ち受けずに残っているときは、それを閉じずにリレーだけ止めて終了コード 1。メッセージをユーザーに伝える。
ユーザーがその Chrome を使っている可能性があるので、頼まれたときだけ実行する。
状態確認は `${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh status`。

## Chrome だけ起動する(ssh のポート転送用)

GUI のあるこの Windows で Chrome を動かし、ssh のポート転送でログイン先の MCP から使うときのもの。
「Chrome だけ起動して」「転送用に Chrome を立てて」などと頼まれたら
`${CLAUDE_SKILL_DIR}/scripts/chrome-cdp.sh start --no-relay` を実行する。明示的に頼まれているので確認は不要。

- リレーには触らない。Chrome を起動し(起動済みなら何もしない)、Windows 側から 127.0.0.1:9222 が
  CDP に応答することを確かめるだけ。
- 転送は Windows で動かす ssh で行う(例: `ssh -R 9222:127.0.0.1:9222 <ログイン先>`)。ログイン先の MCP は
  `--browser-url=http://127.0.0.1:9222` で繋ぐ。WSL の ssh から転送するなら Windows の 127.0.0.1 に届かないので、
  普通の start でリレーを立て、`browser-url:` に出るゲートウェイ IP:9222 を転送先にする。
- start しない条件、失敗したときの対応、停止は普通の start と同じ。ただし start し直すときは `start --no-relay` にする
  (普通の start だとリレーを立ててしまう)。

## 前提と注意

- WSL が NAT のとき: Chrome の CDP は Windows の 127.0.0.1 でしか待ち受けないので、リレーが WSL の
  デフォルトゲートウェイ IP:9222 を中継する。LAN 側には開かない。
- WSL が mirrored のとき(`wslinfo --networking-mode` で自動判定): 127.0.0.1 を Windows と共有していて、
  ゲートウェイはルーターなのでリレーは立てない(start は自動で `--no-relay` 相当)。MCP は常に WSL の 127.0.0.1:9222 に繋ぐ。
- WSL を再起動するとゲートウェイ IP が変わる。`start` はリレーを今の IP で立て直す。
- CDP には認証が無く、WSL 内のプロセスは誰でもこの Chrome を操作できる。プロファイルは普段使いと別のもの
  (環境変数 `CHROME_CDP_USER_DATA_DIR`、既定は `%USERPROFILE%\.cache\chrome-cdp\profile`)を使う。個人のアカウントでログインしない。
- MCP サーバーの登録(user スコープ)。消えていたらこれで登録し直す。接続先は起動時に決める
  (mirrored か、WSL の :9222 で何かが待ち受けていれば 127.0.0.1、いなければゲートウェイ IP):

  ```bash
  claude mcp add-json chrome-devtools --scope user '{"type":"stdio","command":"bash","args":["-c","if wslinfo --networking-mode 2>/dev/null | grep -q mirrored || ss -ltnH sport = :9222 | grep -q .; then h=127.0.0.1; else read -r _ _ h _ < <(ip route show default); fi; exec npx -y chrome-devtools-mcp@latest --browser-url=http://$h:9222 --no-usage-statistics"]}'
  ```
