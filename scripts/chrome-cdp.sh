#!/bin/bash
#
# chrome-cdp.sh <status|start [--no-relay]|stop|help> - Windows の Chrome を CDP 付きで起動し、NAT の WSL2 から使えるようにする
#
#   Chrome の --remote-debugging-port は Windows の 127.0.0.1 でしか待ち受けないため、
#   Windows 側に TCP リレー(cdp-relay.ps1)を立て、WSL のデフォルトゲートウェイ
#   (= WSL 側から見た Windows ホストの IP):PORT を 127.0.0.1:PORT へ中継する。
#   リレーは LAN 側では待ち受けない。CDP には認証が無いので、WSL 内のプロセスは誰でも
#   この Chrome を操作できる。普段のプロファイルとは別の USER_DATA_DIR を使うこと。
#
#   WSL を再起動するとゲートウェイ IP が変わる。start はリレーが今の IP で待ち受けて
#   いなければ立て直す。stop はリレーが無くても、閉じる間だけ立てて Chrome を閉じる。
#
#   127.0.0.1:PORT を USER_DATA_DIR の Chrome 以外(WSL 内の待ち受けを転送する wslrelay.exe など)が
#   使っていたら、start はリレーを立てずに止まり、stop はそれを閉じない。
#
#   WSL が mirrored モード(wslinfo --networking-mode)のときは、Windows と 127.0.0.1 を共有していて
#   デフォルトゲートウェイも Windows ではなくルーターなので、リレーは立てない(start は自動で --no-relay 相当、
#   stop / status も 127.0.0.1 に直接繋ぐ)。
#
#   start は Chrome を --disable-extensions 付きで起動する(拡張機能の content script が画面の書き換えに
#   反応して、操作のたびに数秒固まったことがある)。
#
#   リレーと Chrome が動いているかは、TCP の一覧(netstat.exe)ではなく Windows のプロセスのコマンドラインで判定する
#   (scan)。Windows によっては一覧から待ち受けの行が時々抜けるため(「状態の判定」のコメント)。stop は、CDP で
#   応答した Chrome 本体の PID が USER_DATA_DIR の Chrome と一致するかを、status・start でも確かめる(stop は一致するときだけ閉じる)。
#
#   start --no-relay はリレーに触れず、Chrome を起動するだけ。この Windows で動かす ssh の
#   ポート転送(ssh -R 9222:127.0.0.1:9222 など)で、ログイン先の MCP から使うときのため。
#
#   MCP サーバー chrome-devtools(user スコープに登録)は、起動時に WSL の PORT で何かが待ち受けていれば
#   WSL の 127.0.0.1:PORT に、いなければこのリレーに繋ぐ。待ち受けているのは普通、ssh でログインしてきた
#   端末の Chrome を ssh -R PORT:127.0.0.1:PORT で WSL に転送したもの。status の ssh-tunnel: 行は
#   WSL の PORT で待ち受けているのが ssh の転送かどうかとその先が CDP に応答するかを、mcp: 行は
#   このセッションの MCP の実際の接続先を出す。
#   skill chrome-cdp の一部で、リレー本体は同じディレクトリの cdp-relay.ps1。
#

set -euo pipefail

DEFAULT_PORT=9222
DEFAULT_CHROME_EXE="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
# Windows 側の作業ディレクトリ。既定のプロファイル(profile)とリレーのコピー(cdp-relay.ps1)を置く。
#   本人しか読み書きできない %USERPROFILE% の下にする。C:\temp などはログインできる全員が読み書きできるので、
#   ほかのユーザーにプロファイル(履歴など)を読まれたり、書き換えられたりする。
WIN_BASE_DESC='%USERPROFILE%\.cache\chrome-cdp'
PORT=${CHROME_CDP_PORT:-$DEFAULT_PORT}
CHROME_EXE=${CHROME_CDP_EXE:-$DEFAULT_CHROME_EXE}
# USER_DATA_DIR と CHROME_ARGS は、%USERPROFILE% を cmd.exe で聞いてから init_paths で決める
WIN_BASE='' USER_DATA_DIR='' CHROME_ARGS=()
PROG=$(basename "$0")
REPO_URL=https://github.com/izumo-m/chrome-cdp
SCRIPT_DIR=$(dirname "$(realpath "$0")")
RELAY_SRC=$SCRIPT_DIR/cdp-relay.ps1
LOG=/tmp/chrome-cdp-relay.log
WAIT_SECS=15

CMD=/mnt/c/Windows/System32/cmd.exe
NETSTAT=/mnt/c/Windows/System32/netstat.exe
PWSH=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
CURL_WIN=/mnt/c/Windows/System32/curl.exe

die() { echo "error: $*" >&2; exit 1; }

# 引数を、bash にそのまま貼れる 1 行のコマンドにする。
#   空白・\ などを含むものだけを '…' で囲む(printf %q は \ を \\ にして Windows のパスが読みにくい)。
quote_cmd() {
    local a out=()
    for a in "$@"; do
        if [[ $a =~ ^[A-Za-z0-9_./:=,+@%-]+$ ]]; then
            out+=("$a")
        else
            out+=("'${a//\'/\'\\\'\'}'")
        fi
    done
    echo "${out[*]}"
}

# 条件のコマンドが成功するまで最大 WAIT_SECS 秒待つ。
#   回数でなく経過時間で区切る。リレー越しの接続は Chrome が起動前だと拒否まで数秒かかるため。
wait_for() {
    local end=$((SECONDS + WAIT_SECS))
    until "$@"; do
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 0.5
    done
}

# WSL のネットワークモード(nat / mirrored など)。wslinfo が無い・失敗する古い WSL は nat とみなす。
net_mode() { wslinfo --networking-mode 2>/dev/null | tr -d '\r' || echo nat; }
is_mirrored() { [ "$(net_mode)" = mirrored ]; }

# パイプの awk は途中で exit しない。前段が SIGPIPE で死に、pipefail + set -e で無言終了するため。
host_ip() { ip route show default | awk 'NR == 1 {print $3}'; }

# Windows 側の作業ディレクトリ(%USERPROFILE%\.cache\chrome-cdp を展開したもの)を WIN_BASE に入れる。
#   取得できなければ非 0 を返す。変数に入れるので $(...) では呼ばない。
win_base() {
    local up
    [ -z "$WIN_BASE" ] || return 0
    up=$(cd /mnt/c && "$CMD" /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
    [ -n "$up" ] && [ "$up" != '%USERPROFILE%' ] || return 1
    WIN_BASE="$up\\.cache\\chrome-cdp"
}

# start が Chrome に渡す引数。拡張機能は無効にする(拡張機能の content script が画面の書き換えに反応して、
# 操作のたびに数秒固まったことがある)
set_chrome_args() {
    CHROME_ARGS=(--remote-debugging-port="$PORT" --user-data-dir="$USER_DATA_DIR" --disable-extensions)
}

# USER_DATA_DIR(CHROME_CDP_USER_DATA_DIR、無ければ WIN_BASE\profile)と CHROME_ARGS を決める。
#   status / start / stop の前に呼ぶ。
init_paths() {
    if [ -n "${CHROME_CDP_USER_DATA_DIR:-}" ]; then
        USER_DATA_DIR=$CHROME_CDP_USER_DATA_DIR
    else
        win_base || die "Windows の USERPROFILE を取得できない(WSL の interop を確認する)"
        USER_DATA_DIR="$WIN_BASE\\profile"
    fi
    set_chrome_args
}

# リレー本体の Windows 側コピー先(WIN_BASE の WSL のパス)。
#   \\wsl.localhost 上の .ps1 を直接実行させず、Windows のローカルパスに置いて実行する。
win_dir() {
    win_base || die "Windows の USERPROFILE を取得できない(WSL の interop を確認する)"
    wslpath -u "$WIN_BASE"
}

# ---- 状態の判定 ----
#
#   待ち受けているかどうかは、TCP の一覧(netstat.exe / Get-NetTCPConnection)では判定しない。Windows によっては
#   一覧から待ち受けの行が時々抜ける(状態の列も壊れる)ため。ポートに繋いで確かめることもしない(mirrored では
#   待ち受けていないポートへの接続がすぐに拒否されず固まる)。代わりに Windows のプロセスのコマンドラインで判定する。
#     - リレー: cdp-relay.ps1 は待ち受けに失敗すると終了するので、プロセスがあれば待ち受けている。
#     - Chrome: USER_DATA_DIR の Chrome が --remote-debugging-port=PORT 付きで動いていれば CDP 付き。
#   TCP の一覧は、ポートを使っている相手をメッセージに添えるための補助にだけ使う。

# scan が PowerShell で実行するスクリプト。PORT と USER_DATA_DIR は環境変数(WSLENV で渡す)で受け取る。
#   出力は "relay <pid> <待ち受けアドレス>"、"own <pid> <--remote-debugging-port の値>"、
#   "other <pid> <--user-data-dir の値>"(ほかのプロファイルで --remote-debugging-port=PORT のもの)で、最後に "end"。
#   other に --user-data-dir の無い Chrome(既定のプロファイル)は含めない。Chrome 136 以降は、既定のプロファイルでは
#   --remote-debugging-port を無視して待ち受けないので、フラグが付いているだけの普段使いの Chrome を誤って数えないため。
#   --user-data-dir は、引数全体が引用符で囲まれた形("--user-data-dir=C:\a b"。WSL の interop で起動するとこうなる)も読む。
#   パスに日本語があっても崩れないよう、出力は UTF-8 にする。
SCAN_PS=$(cat <<'EOF'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$port = $env:CDP_PORT
$re = '--user-data-dir="?' + [regex]::Escape($env:CDP_DIR) + '"?(\s|$)'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='chrome.exe'" -ErrorAction Stop | ForEach-Object {
    $c = [string]$_.CommandLine
    if ($_.Name -eq 'powershell.exe') {
        if ($_.ProcessId -ne $PID -and $c -match ('cdp-relay\.ps1"?\s.*-ListenAddress\s+"?([0-9.]+)"?\s.*-Port\s+"?' + $port + '\b')) {
            'relay ' + $_.ProcessId + ' ' + $Matches[1]
        }
    } elseif ($c -notmatch '--type=') {
        $own = $c -match $re
        $p = ''
        if ($c -match '--remote-debugging-port=(\d+)') { $p = $Matches[1] }
        if ($own) {
            'own ' + $_.ProcessId + ' ' + $p
        } elseif ($p -eq $port) {
            $d = ''
            if ($c -match '"--user-data-dir=([^"]*)"') { $d = $Matches[1] }
            elseif ($c -match '--user-data-dir="([^"]*)"') { $d = $Matches[1] }
            elseif ($c -match '--user-data-dir=(\S+)') { $d = $Matches[1] }
            if ($d -ne '') { 'other ' + $_.ProcessId + ' ' + $d }
        }
    }
}
'end'
EOF
)
SCAN_ENC=''

# Windows のプロセスを読んで、次の変数に入れる(無ければ空)。変数に入れるので $(...) では呼ばない。
#   RELAYS     PORT のリレーの "<pid> <待ち受けアドレス>"(1 行に 1 つ)
#   OWN_PID    USER_DATA_DIR の Chrome のブラウザプロセス(--type= の無いもの)の PID
#   OWN_PORT   その Chrome の --remote-debugging-port の値(付いていなければ空)
#   OTHER_PID  ほかのプロファイル(--user-data-dir 付き)で --remote-debugging-port=PORT 付きの Chrome の PID
#   OTHER_DIR  その --user-data-dir
#   読めなければ die する(検出漏れで「止まっている」と見誤ったり、ウィンドウを開いたりしないよう)。
RELAYS='' OWN_PID='' OWN_PORT='' OTHER_PID='' OTHER_DIR=''
scan() {
    local out own other
    [ -n "$SCAN_ENC" ] || SCAN_ENC=$(printf '%s' "$SCAN_PS" | iconv -f utf-8 -t utf-16le | base64 -w0)
    out=$(cd /mnt/c && CDP_PORT=$PORT CDP_DIR=$USER_DATA_DIR WSLENV="${WSLENV:+$WSLENV:}CDP_PORT:CDP_DIR" \
        "$PWSH" -NoProfile -NonInteractive -EncodedCommand "$SCAN_ENC" 2>/dev/null | tr -d '\r') || true
    [ "$(printf '%s\n' "$out" | awk 'END {print}')" = end ] \
      || die "Windows のプロセスを確認できない(powershell.exe が動かない。WSL の interop を確認する)"
    RELAYS=$(printf '%s\n' "$out" | awk '$1 == "relay" {print $2, $3}')
    own=$(printf '%s\n' "$out" | awk '$1 == "own" && !f {print $2, $3; f = 1}')
    other=$(printf '%s\n' "$out" | awk '$1 == "other" && !f {sub(/^other /, ""); print; f = 1}')
    read -r OWN_PID OWN_PORT <<<"$own"
    read -r OTHER_PID OTHER_DIR <<<"$other"
}

# scan の後で使うもの
relay_pid() { printf '%s\n' "$RELAYS" | awk -v a="$1" '$2 == a && !f {print $1; f = 1}'; }   # アドレス $1 のリレー
own_cdp() { [ -n "$OWN_PID" ] && [ "$OWN_PORT" = "$PORT" ]; }   # USER_DATA_DIR の Chrome が CDP 付きで動いている

# wait_for で待つ条件(scan し直して判定する)
relay_running() { scan; [ -n "$(relay_pid "$1")" ]; }
profile_gone() { scan; [ -z "$OWN_PID" ]; }

# ADDR:PORT を LISTEN している Windows PID(無ければ空)。TCP の一覧は当てにならないので、見つかったときに
# メッセージに添えるためだけに使う(見つからなくても「待ち受けていない」とはみなさない)。
#   状態列はロケール依存で、壊れていることもあるので、外部アドレス 0.0.0.0:0 で LISTEN 行を見分ける。
listen_pid() {
    local out
    out=$(cd /mnt/c && "$NETSTAT" -ano -p TCP 2>/dev/null) || return 0
    printf '%s\n' "$out" | tr -d '\r' \
      | awk -v a="$1" -v p=":$PORT" '
            $1 == "TCP" && $3 == "0.0.0.0:0" && $2 == a p && !found { print $NF; found = 1 }'
}

cdp_version() {
    curl -fs --noproxy '*' --connect-timeout 2 --max-time 5 "http://$1:$PORT/json/version" \
      | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p'
}
cdp_ok() { [ -n "$(cdp_version "$1")" ]; }
# リレーを通さず、Windows 側から 127.0.0.1:PORT に聞く
win_cdp_ok() {
    [ -n "$(cd /mnt/c && "$CURL_WIN" -fs --noproxy '*' --connect-timeout 2 --max-time 5 "http://127.0.0.1:$PORT/json/version" 2>/dev/null \
      | tr -d '\r' | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')" ]
}

kill_relay() {
    # 終了を待ってから戻る(待たないと直後の start で同じアドレスへの bind が失敗しうる)
    "$PWSH" -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -match 'cdp-relay\\.ps1\"? .*-Port $PORT\\b' -and \$_.ProcessId -ne \$PID } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue; Wait-Process -Id \$_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }" \
      >/dev/null 2>&1 || true
}

# リレーが ADDR で待ち受けを始めたか(ログに待ち受けの行が出ていて、プロセスが残っている)
relay_ready() { grep -qF "listening on $1:$PORT " "$LOG" 2>/dev/null && relay_running "$1"; }

start_relay() {
    local ip=$1 dir
    [ -f "$RELAY_SRC" ] || die "リレースクリプトが無い: $RELAY_SRC"
    kill_relay   # 古い IP で待ち受けている旧リレーを片付ける
    dir=$(win_dir)
    mkdir -p "$dir"
    cp "$RELAY_SRC" "$dir/cdp-relay.ps1"
    setsid "$PWSH" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
        -File "$(wslpath -w "$dir/cdp-relay.ps1")" -ListenAddress "$ip" -Port "$PORT" \
        </dev/null >"$LOG" 2>&1 &
    wait_for relay_ready "$ip" \
      || die "リレーが ${ip}:$PORT で待ち受けない。ログ $LOG: $(tail -n 3 "$LOG" 2>/dev/null | tr -d '\r' | paste -sd ' ')"
    echo "relay: ${ip}:$PORT -> 127.0.0.1:$PORT (win pid $(relay_pid "$ip"))"
}

# --user-data-dir=USER_DATA_DIR を含むコマンドラインに一致する正規表現を、PowerShell の $re に入れる文
profile_re() {
    local d=${USER_DATA_DIR//\'/\'\'}
    printf '%s' "\$re = '--user-data-dir=\"?' + [regex]::Escape('$d') + '\"?(\s|\$)'"
}

# Windows PID のプロセスが USER_DATA_DIR の Chrome なら profile、違えばプロセス名(プロセスが無ければ空)を出す。
#   PowerShell が失敗したら非 0 を返す。
proc_kind() {
    "$PWSH" -NoProfile -Command \
      "$(profile_re); \$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$1' -ErrorAction Stop; if (\$p.Name -eq 'chrome.exe' -and \$p.CommandLine -match \$re) { 'profile' } else { \$p.Name }" \
      2>/dev/null | tr -d '\r'
}

# scan の後で、127.0.0.1:PORT を USER_DATA_DIR の Chrome 以外が使っている(使っていそうな)ときは、その説明を
# CONFLICT に入れる(無ければ空)。変数に入れるので $(...) では呼ばない。
#   USER_DATA_DIR の Chrome が CDP 付きで動いているときは何もしない。ポートを本当にその Chrome が持っているかは、
#   CDP で応答した Chrome 本体の PID で確かめる(check_responder)。フラグが付いているだけの Chrome もあるため。
#   そうでないとき(これから start するときなど)は、次のものを見る。
#   - ほかのプロファイルの Chrome が --remote-debugging-port=PORT 付きで動いている。
#   - WSL 内のプロセスが PORT で待ち受けている(NAT では WSL の localhost 転送の wslrelay.exe が Windows の
#     127.0.0.1:PORT を取る。mirrored では 127.0.0.1 が共通)。
#   - TCP の一覧に 127.0.0.1:PORT の待ち受けがあり、その PID が USER_DATA_DIR の Chrome でない(一覧に出たときだけ)。
CONFLICT=''
check_conflict() {
    local pid kind
    CONFLICT=''
    if own_cdp; then
        return 0
    fi
    if [ -n "$OTHER_PID" ]; then
        CONFLICT="127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている($OTHER_DIR の Chrome, win pid $OTHER_PID)"
        return 0
    fi
    if [ -n "$(ss -ltnH "sport = :$PORT" 2>/dev/null)" ]; then
        if is_mirrored; then
            CONFLICT="127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている(WSL 内のプロセスが $PORT で待ち受けている。mirrored では 127.0.0.1 が Windows と共通。status の ssh-tunnel: 行に相手が出る)"
        else
            CONFLICT="127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている(wslrelay.exe)。WSL 内のプロセスが $PORT で待ち受けている(status の ssh-tunnel: 行に相手が出る)"
        fi
        return 0
    fi
    pid=$(listen_pid 127.0.0.1)
    [ -n "$pid" ] || return 0
    kind=$(proc_kind "$pid") || return 0   # 補助なので、確かめられなければ何も言わない
    [ -n "$kind" ] && [ "$kind" != profile ] || return 0
    CONFLICT="127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている($kind, win pid $pid)"
}

# http://HOST:PORT の CDP に応答した Chrome 本体の "<PID> <Browser>"(例: "14408 Chrome/157.0.…")。応答が無ければ空。
#   PID は SystemInfo.getProcessInfo の type=browser のもの。待ち受けていないポートに繋ぐと固まることがある
#   (mirrored)ので、scan で Chrome がいると分かったときだけ呼び、5 秒で打ち切る。
cdp_info() {
    node -e '
        setTimeout(() => process.exit(1), 5000);
        (async () => {
            const v = await (await fetch(process.argv[1] + "/json/version")).json();
            const ws = new WebSocket(v.webSocketDebuggerUrl);
            ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "SystemInfo.getProcessInfo" }));
            ws.onmessage = (e) => {
                const m = JSON.parse(e.data);
                if (m.id !== 1) return;
                const b = (m.result?.processInfo ?? []).find((p) => p.type === "browser");
                console.log(`${b?.id ?? "?"} ${v.Browser ?? "?"}`);
                process.exit(0);
            };
            ws.onerror = () => process.exit(1);
        })().catch(() => process.exit(1));
    ' "http://$1:$PORT" 2>/dev/null || true
}

# scan の後で、HOST から PORT の CDP に応答するのが USER_DATA_DIR の Chrome(OWN_PID)かを確かめる。
#   一致すれば 0 を返し、CDP_BROWSER にバージョン(例: Chrome/157.0.…)を入れる。応答が無ければ 1 を返す。
#   別の Chrome が応答したら 2 を返し、CONFLICT に説明を入れる(ssh の転送などが先に 127.0.0.1:PORT を取っていて、
#   USER_DATA_DIR の Chrome は待ち受けに失敗している)。変数に入れるので $(...) では呼ばない。
CDP_BROWSER=''
check_responder() {
    local info
    CDP_BROWSER=''
    info=$(cdp_info "$1")
    [ -n "$info" ] || return 1
    if [ "${info%% *}" != "$OWN_PID" ]; then
        CONFLICT="127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている(CDP で応答したのは別の Chrome(pid ${info%% *})。$USER_DATA_DIR の Chrome(win pid ${OWN_PID:-?})はポートを取れていない)"
        return 2
    fi
    CDP_BROWSER=${info#* }
}

# scan の後で、USER_DATA_DIR の Chrome が残っているが、PORT で CDP 付きではないときの説明
own_state() {
    if [ -z "$OWN_PORT" ]; then
        echo "$USER_DATA_DIR の Chrome が CDP なしで起動している(win pid $OWN_PID)"
    else
        echo "$USER_DATA_DIR の Chrome が 127.0.0.1:$PORT で待ち受けずに残っている(--remote-debugging-port=$OWN_PORT, win pid $OWN_PID)"
    fi
}

# CDP が応答するか、USER_DATA_DIR の Chrome が消えるまで(起動中・終了中の Chrome を待つ)
cdp_or_gone() { win_cdp_ok || profile_gone; }

start_chrome() {
    local msg
    [ -f "$CHROME_EXE" ] || die "Chrome が見つからない: $CHROME_EXE"
    scan
    if own_cdp; then
        # 起動中か、閉じた直後で終了中のこともあるので、CDP が応答するか、消えるまで待つ
        wait_for cdp_or_gone \
          || die "$USER_DATA_DIR の Chrome(win pid $OWN_PID)が 127.0.0.1:$PORT で CDP に応答しない。stop してから start し直す"
        if [ -n "$OWN_PID" ]; then
            echo "chrome: running"
            return
        fi
    elif [ -n "$OWN_PID" ]; then
        # 同じプロファイルの Chrome が残っていると、新しい起動はそちらに引き渡されてポートが開かず、
        # ユーザーの画面にウィンドウが増えるだけになる。閉じた直後はプロセスがしばらく残るので、消えるまで待つ。
        if ! wait_for profile_gone; then
            msg=$(own_state)
            die "$msg。閉じてから start し直す"
        fi
    fi
    echo "chrome: run: $(quote_cmd "$CHROME_EXE" "${CHROME_ARGS[@]}")"
    setsid "$CHROME_EXE" "${CHROME_ARGS[@]}" </dev/null >/dev/null 2>&1 &
    wait_for win_cdp_ok || die "Chrome が 127.0.0.1:$PORT で CDP に応答しない"
    echo "chrome: started ($USER_DATA_DIR)"
}

# Browser.close で、USER_DATA_DIR の Chrome(scan で得た OWN_PID)を正常終了させる
# (Stop-Process だと次回「正しく終了しませんでした」が出る)。閉じられなかったら、その理由を出して非 0 を返す。
#   CDP で応答した Chrome 本体の PID(SystemInfo.getProcessInfo)が OWN_PID と違えば閉じない。NAT で WSL の
#   localhost 転送(wslrelay.exe)が先に 127.0.0.1:PORT を取っていると、リレーの先は ssh の転送の先など別の Chrome になる。
#   Browser.close を送った後は、接続の切れ方によっては onerror になるので、node の終了コードではなく
#   Chrome のプロセスが消えたかで成否を判定する。
#   リレーや Chrome が固まっていると fetch も返らない(既定の打ち切りは 300 秒)ので、5 秒の打ち切りは最初に仕掛ける。
close_chrome() {
    local out rc=0
    out=$(node -e '
        const [url, pid] = process.argv.slice(1);
        let closing = false;
        const fail = (msg) => { console.log(msg); process.exit(1); };
        setTimeout(() => (closing ? process.exit(0) : fail("CDP が 5 秒以内に応答しない")), 5000);
        (async () => {
            const v = await (await fetch(url + "/json/version")).json();
            const ws = new WebSocket(v.webSocketDebuggerUrl);
            ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "SystemInfo.getProcessInfo" }));
            ws.onmessage = (e) => {
                const m = JSON.parse(e.data);
                if (m.id !== 1) return;
                const b = (m.result?.processInfo ?? []).find((p) => p.type === "browser");
                if (String(b?.id) !== pid) {
                    console.log(`CDP で応答した Chrome(win pid ${b?.id ?? "?"})が閉じる対象(win pid ${pid})と違うので閉じない`);
                    process.exit(3);
                }
                closing = true;
                ws.send(JSON.stringify({ id: 2, method: "Browser.close" }));
            };
            ws.onclose = ws.onerror = () => (closing ? process.exit(0) : fail("CDP の接続が切れた"));
        })().catch((e) => fail(`CDP に繋がらない(${e.message})`));
    ' "http://$1:$PORT" "$OWN_PID") || rc=$?
    if [ "$rc" != 0 ]; then
        echo "$out"
        return 1
    fi
    # Browser.close の後もプロセスはしばらく残るので、消えるまで待つ(直後の start が引き渡されないように)
    if ! wait_for profile_gone; then
        echo "Browser.close の後も Chrome(win pid $OWN_PID)が終了しない"
        return 1
    fi
}

do_start() {
    local relay=1 ip="" again=start
    case "${1:-}" in
        '') ;;
        --no-relay) relay=0; again="start --no-relay" ;;
        *) usage "start の不明なオプション: $1" ;;
    esac
    if [ "$relay" = 1 ] && is_mirrored; then
        relay=0; again=start
        echo "network: mirrored(127.0.0.1 が Windows と共通なのでリレーは立てない)"
    fi
    if [ "$relay" = 1 ]; then
        ip=$(host_ip)
        [ -n "$ip" ] || die "デフォルトゲートウェイが取得できない"
    fi
    # 中継先が USER_DATA_DIR の Chrome でなければリレーを立てても意味が無いので、先に確かめる
    scan
    check_conflict
    [ -z "$CONFLICT" ] || die "$CONFLICT"
    if [ "$relay" = 1 ]; then
        if [ -n "$(relay_pid "$ip")" ]; then
            echo "relay: running on ${ip}:$PORT"
        else
            start_relay "$ip"
        fi
    fi
    start_chrome
    # 応答しているのが USER_DATA_DIR の Chrome かを、CDP で応答した Chrome 本体の PID で確かめる
    # (起動の間に ssh の転送などが 127.0.0.1:PORT を先に取ると、Chrome は待ち受けに失敗したまま動き続ける)。
    # NAT の start --no-relay では WSL から 127.0.0.1:PORT に届かないので、Windows 側から応答を確かめるだけにする。
    scan
    if [ "$relay" = 0 ]; then
        wait_for win_cdp_ok || die "127.0.0.1:$PORT が CDP に応答しない(win pid ${OWN_PID:-?})。stop してから $again し直す"
        if is_mirrored; then
            wait_for cdp_ok 127.0.0.1 || die "WSL の 127.0.0.1:$PORT から CDP に届かない(mirrored)。stop してから $again し直す"
            verify_responder 127.0.0.1 "$again"
        fi
        echo "browser-url: http://127.0.0.1:$PORT (リレーは触っていない)"
        return
    fi
    wait_for cdp_ok "$ip" || die "127.0.0.1:$PORT が CDP に応答しない(win pid ${OWN_PID:-?})。stop してから $again し直す"
    verify_responder "$ip" "$again"
    echo "browser-url: http://${ip}:$PORT"
}

# start の最後に、HOST から応答するのが USER_DATA_DIR の Chrome かを確かめ、違えば die する($2 は案内する start)
verify_responder() {
    local rc=0
    check_responder "$1" || rc=$?
    case $rc in
        0) ;;
        2) die "$CONFLICT。stop してから $2 し直す" ;;
        *) die "127.0.0.1:$PORT が CDP に応答しない(win pid ${OWN_PID:-?})。stop してから $2 し直す" ;;
    esac
}

do_stop() {
    local ip msg rc=0 mirrored=0
    if is_mirrored; then
        mirrored=1; ip=127.0.0.1   # リレーは無い。Chrome に直接繋ぐ
    else
        ip=$(host_ip)
        [ -n "$ip" ] || die "デフォルトゲートウェイが取得できない"
    fi
    trap kill_relay EXIT   # 途中で die しても、リレーは止めて終わる(下の kill_relay まで外さない)
    scan
    check_conflict
    if own_cdp; then
        # WSL の再起動後などでリレーが無いと閉じられないので、閉じる間だけ立てる
        if [ "$mirrored" = 0 ] && [ -z "$(relay_pid "$ip")" ]; then
            start_relay "$ip" >/dev/null
        fi
        if msg=$(close_chrome "$ip"); then
            echo "chrome: closed"
        else
            echo "chrome: ${msg:-閉じられなかった}。手で閉じる"
            rc=1
        fi
    elif [ -n "$OWN_PID" ]; then
        msg=$(own_state)
        echo "chrome: $msg。CDP では閉じられない(手で閉じる)"
        rc=1
    elif [ -n "$CONFLICT" ]; then
        echo "chrome: $CONFLICT。閉じない"
        rc=1
    else
        echo "chrome: not running"
    fi
    kill_relay
    trap - EXIT
    if [ "$mirrored" = 1 ]; then
        echo "relay: not used (mirrored)"
        return "$rc"
    fi
    scan
    if [ -n "$RELAYS" ]; then
        echo "relay: 止まらない(win pid $(printf '%s\n' "$RELAYS" | awk '{print $1}' | paste -sd ' '))"
        rc=1
    else
        echo "relay: stopped"
    fi
    return "$rc"
}

# WSL 内で PORT を待ち受けているもの(ssh -R の転送の受け口)を見て ssh-tunnel: 行を出す。
#   転送の受け口はログインしたユーザーの uid の sshd-session が持つが、root から uid を切り替えたプロセスなので
#   /proc が読めず、ss -p でも名前が見えない。名前が見えず uid が自分のものを転送とみなす。
#   docker-proxy など root のプロセスも名前は見えないが、ss -e で uid が出ないので区別できる。
tunnel_line() {
    local out line name uid ver
    if ! out=$(ss -ltnpeH "sport = :$PORT" 2>/dev/null); then
        echo "ssh-tunnel: ? (ss が失敗)"
        return
    fi
    line=$(printf '%s\n' "$out" | awk 'NR == 1')
    if [ -z "$line" ]; then
        echo "ssh-tunnel: no"
        return
    fi
    name=$(printf '%s\n' "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
    uid=$(printf '%s\n' "$line" | sed -n 's/.* uid:\([0-9]*\).*/\1/p')
    if [ -z "$name" ] && [ "${uid:-0}" = "$(id -u)" ]; then
        ver=$(cdp_version 127.0.0.1) || ver=''
        echo "ssh-tunnel: yes (${ver:-転送の先が CDP に応答しない})"
    else
        echo "ssh-tunnel: no (WSL の :$PORT を ${name:-uid ${uid:-0} のプロセス} が待ち受けている)"
    fi
}

# このスクリプトを実行している claude(祖先のプロセスで最初の claude)が起動した MCP chrome-devtools の接続先 URL。
#   見つからなければ空。npx に exec する前の bash -c の引数($h のまま)は拾わない。
mcp_urls() {
    local pid=$$ comm out
    while [ "${pid:-0}" -gt 1 ]; do
        comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
        [ "$comm" != claude ] || break
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
    done
    [ "${pid:-0}" -gt 1 ] || return 0
    out=$(ps -o args= --ppid "$pid" 2>/dev/null) || return 0
    printf '%s\n' "$out" \
      | sed -n 's|.*chrome-devtools-mcp.* --browser-url=\(http://[0-9.]*:[0-9]*\).*|\1|p' | sort -u
}

# mcp: 行。MCP は起動時(セッションの開始・resume、/mcp での再接続)に接続先を決めるので、
# その後で WSL の PORT の待ち受け(ssh の転送)が始まった・終わったときは、今起動し直したときの接続先も出す。
mcp_line() {
    local ip=$1 url now
    url=$(mcp_urls)
    if [ -z "$url" ]; then
        echo "mcp: ? (このセッションの chrome-devtools のプロセスが見つからない)"
        return
    fi
    if [ "$(printf '%s\n' "$url" | wc -l)" -gt 1 ]; then
        echo "mcp: ? (接続先が複数ある: $(printf '%s\n' "$url" | paste -sd ' '))"
        return
    fi
    if ! now=$(ss -ltnH "sport = :$PORT" 2>/dev/null); then
        now=''   # 判定できないので比べない
    elif [ -n "$now" ]; then
        now=http://127.0.0.1:$PORT
    else
        now=http://$ip:$PORT
    fi
    case "$url" in
        "http://127.0.0.1:$PORT") printf 'mcp: %s (WSL の 127.0.0.1。相手は ssh-tunnel: 行)' "$url" ;;
        "http://$ip:$PORT") printf 'mcp: %s (リレー経由でこの Windows の Chrome)' "$url" ;;
        *) printf 'mcp: %s (今のゲートウェイ IP でも 127.0.0.1 でもない)' "$url" ;;
    esac
    [ -z "$now" ] || [ "$now" = "$url" ] \
      || printf '。今の状態とずれている(今起動し直すと %s に繋ぐ。/mcp で chrome-devtools を再接続してもらう)' "$now"
    echo
}

do_status() {
    local ip rpid='' stale rc mirrored=0
    ip=$(host_ip)
    if is_mirrored; then mirrored=1; ip=127.0.0.1; echo "network: mirrored(リレー不要。127.0.0.1 を共有)"; else echo "host ip: ${ip:-?}"; fi
    tunnel_line
    mcp_line "$ip"
    scan
    if [ "$mirrored" = 1 ]; then
        echo "relay: not used (mirrored)"
    else
        [ -z "$ip" ] || rpid=$(relay_pid "$ip")
        if [ -n "$rpid" ]; then
            echo "relay: running (win pid $rpid)"
        else
            stale=$(printf '%s\n' "$RELAYS" | awk 'NF {print $2}' | paste -sd ' ')
            echo "relay: stopped${stale:+(古いゲートウェイ IP $stale で待ち受けているリレーが残っている。start で立て直す)}"
        fi
    fi
    check_conflict
    if [ -n "$CONFLICT" ]; then
        echo "chrome: $CONFLICT"
    elif [ -z "$OWN_PID" ]; then
        echo "chrome: not running"
    elif ! own_cdp; then
        echo "chrome: $(own_state)"
    elif [ "$mirrored" = 0 ] && [ -z "$rpid" ]; then
        echo "chrome: running (win pid $OWN_PID, リレーが無いので WSL からは届かない)"
    else
        rc=0
        check_responder "$ip" || rc=$?
        case $rc in
            0) echo "chrome: $CDP_BROWSER" ;;
            2) echo "chrome: $CONFLICT" ;;
            *) echo "chrome: 127.0.0.1:$PORT (win pid $OWN_PID) が CDP に応答しない" ;;
        esac
    fi
}

# 使い方の誤り。理由(あれば)と短い使い方を標準エラーに出して、終了コード 2 で終える
usage() {
    [ -z "${1:-}" ] || echo "error: $1" >&2
    echo "usage: $PROG <status|start [--no-relay]|stop|help>" >&2
    echo "詳しくは $PROG --help" >&2
    exit 2
}

# 環境変数 $1 の今の値(既定値は $2)。設定されていれば既定値も添える
env_value() {
    local v=${!1:-}
    if [ -z "$v" ]; then
        printf '%s(既定)' "$2"
    else
        printf '%s(設定済み。既定は %s)' "$v" "$2"
    fi
}

show_help() {
    local skill_dir readme update def_udd
    # 既定のプロファイル。USERPROFILE を取得できなくてもヘルプは出す
    if win_base; then def_udd="$WIN_BASE\\profile"; else def_udd="$WIN_BASE_DESC\\profile"; fi
    USER_DATA_DIR=${CHROME_CDP_USER_DATA_DIR:-$def_udd}
    set_chrome_args
    skill_dir=$(realpath -m "$SCRIPT_DIR/..")
    readme=$skill_dir/README.md
    if [ -e "$skill_dir/.git" ]; then
        update="git -C $skill_dir pull --ff-only"
    else
        update="git clone で入れていない($skill_dir)。$REPO_URL のインストールの手順で入れ直す"
    fi
    [ -f "$readme" ] || readme=$REPO_URL
    cat <<EOF
usage: $PROG <command>

Windows の Chrome を CDP 付きで起動し、WSL2 の chrome-devtools MCP から使えるようにする。
WSL が NAT なら、Windows 側に TCP リレーを立てて <ゲートウェイ IP>:$PORT を 127.0.0.1:$PORT に中継する
(mirrored なら立てない)。

コマンド:
  status            リレー・Chrome・ssh の転送・このセッションの MCP の接続先を表示する
  start             リレーと Chrome を起動する(起動済みの部分は何もしない)
  start --no-relay  リレーに触らず Chrome だけ起動する(この Windows から ssh -R で転送するとき)
  stop              Chrome を Browser.close で正常終了させ、リレーを止める
  help              このヘルプを表示する(-h、--help も同じ)

start は Chrome を次のコマンドで起動する(起動していないときだけ):
  $(quote_cmd "$CHROME_EXE" "${CHROME_ARGS[@]}")

環境変数:
  CHROME_CDP_USER_DATA_DIR  Chrome のプロファイル(Windows のパス)。普段使いとは別にする
                            今: $(env_value CHROME_CDP_USER_DATA_DIR "$def_udd")
  CHROME_CDP_EXE            chrome.exe(WSL のパス)
                            今: $(env_value CHROME_CDP_EXE "$DEFAULT_CHROME_EXE")
  CHROME_CDP_PORT           CDP のポート。変えるなら MCP の登録の $DEFAULT_PORT も変える
                            今: $(env_value CHROME_CDP_PORT "$DEFAULT_PORT")
  Claude Code から使うときは ~/.claude/settings.json の env に書く。

リレーのログ: $LOG
終了コード: 0 成功、1 失敗・できなかった(理由を表示する)、2 使い方の誤り

更新: $update
  変更点と、MCP の登録をし直す必要があるかは CHANGELOG.md に書いている。
EOF
    echo "詳しくは $readme"
}

# -h / --help は、どこにあってもヘルプを出す(start --help など)
for arg in "$@"; do
    case $arg in -h|--help) show_help; exit 0 ;; esac
done
case "${1:-}" in
    status) [ $# -le 1 ] || usage "status は引数を取らない"; init_paths; do_status ;;
    start)  [ $# -le 2 ] || usage "start の引数が多い"; init_paths; do_start "${2:-}" ;;
    stop)   [ $# -le 1 ] || usage "stop は引数を取らない"; init_paths; do_stop ;;
    help)   show_help ;;
    '')     usage ;;
    *)      usage "不明なコマンド: $1" ;;
esac
