#!/bin/bash
#
# chrome-cdp.sh <start [--no-relay]|stop|status> - Windows の Chrome を CDP 付きで起動し、NAT の WSL2 から使えるようにする
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

PORT=${CHROME_CDP_PORT:-9222}
CHROME_EXE=${CHROME_CDP_EXE:-"/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"}
USER_DATA_DIR=${CHROME_CDP_USER_DATA_DIR:-'C:\temp\chrome-cdp-profile'}   # 普段使いとは別のプロファイル(無ければ Chrome が作る)
RELAY_SRC=$(dirname "$(realpath "$0")")/cdp-relay.ps1
LOG=/tmp/chrome-cdp-relay.log
WAIT_SECS=15

CMD=/mnt/c/Windows/System32/cmd.exe
NETSTAT=/mnt/c/Windows/System32/netstat.exe
PWSH=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
CURL_WIN=/mnt/c/Windows/System32/curl.exe

die() { echo "error: $*" >&2; exit 1; }

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

# リレー本体の Windows 側コピー先(%LOCALAPPDATA%\chrome-cdp)。
#   \\wsl.localhost 上の .ps1 を直接実行させず、Windows のローカルパスに置いて実行する。
win_dir() {
    local la
    la=$(cd /mnt/c && "$CMD" /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')
    [ -n "$la" ] && [ "$la" != '%LOCALAPPDATA%' ] || die "LOCALAPPDATA を取得できない"
    echo "$(wslpath -u "$la")/chrome-cdp"
}

# ADDR:PORT を LISTEN している Windows PID(無ければ空)。
#   状態列はロケール依存なので、外部アドレス 0.0.0.0:0 で LISTEN 行を見分ける。
#   netstat.exe が動かない(WSL の interop が壊れている)ときは、無言で「停止中」に見えないよう die する。
listen_pid() {
    local out
    out=$("$NETSTAT" -ano -p TCP 2>&1) || die "netstat.exe を実行できない(WSL の interop を確認する)"
    printf '%s\n' "$out" | tr -d '\r' \
      | awk -v a="$1" -v p=":$PORT" '
            $1 == "TCP" && $3 == "0.0.0.0:0" && $2 == a p && !found { print $NF; found = 1 }'
}

# 条件(if / until)の中では $(...) 内の die が効かないので、失敗はここで exit して伝える
relay_up() { local p; p=$(listen_pid "$1") || exit 1; [ -n "$p" ]; }
chrome_up() { local p; p=$(listen_pid 127.0.0.1) || exit 1; [ -n "$p" ]; }
chrome_down() { ! chrome_up; }

cdp_version() {
    curl -fs --noproxy '*' --connect-timeout 2 --max-time 5 "http://$1:$PORT/json/version" \
      | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p'
}
cdp_ok() { [ -n "$(cdp_version "$1")" ]; }
# リレーを通さず、Windows 側から 127.0.0.1:PORT に聞く(start --no-relay 用)
win_cdp_ok() {
    [ -n "$("$CURL_WIN" -fs --noproxy '*' --connect-timeout 2 --max-time 5 "http://127.0.0.1:$PORT/json/version" 2>/dev/null \
      | tr -d '\r' | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')" ]
}

kill_relay() {
    # 終了を待ってから戻る(待たないと直後の start で同じアドレスへの bind が失敗しうる)
    "$PWSH" -NoProfile -Command \
      "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -match 'cdp-relay\\.ps1\"? .*-Port $PORT\\b' -and \$_.ProcessId -ne \$PID } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue; Wait-Process -Id \$_.ProcessId -Timeout 10 -ErrorAction SilentlyContinue }" \
      >/dev/null 2>&1 || true
}

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
    wait_for relay_up "$ip" || die "リレーの LISTEN を確認できない。ログ: $LOG"
    echo "relay: ${ip}:$PORT -> 127.0.0.1:$PORT (win pid $(listen_pid "$ip"))"
}

# --user-data-dir=USER_DATA_DIR を含むコマンドラインに一致する正規表現を、PowerShell の $re に入れる文
profile_re() {
    local d=${USER_DATA_DIR//\'/\'\'}
    printf '%s' "\$re = '--user-data-dir=\"?' + [regex]::Escape('$d') + '\"?(\s|\$)'"
}

# USER_DATA_DIR を使う Chrome のブラウザプロセス(--type= の無いもの)の PID(無ければ空)。
#   nocdp を付けると --remote-debugging-port の無いものに限る。
#   PowerShell が失敗したら非 0 を返す(検出漏れでウィンドウを開かないよう、呼び出し側で止める)。
profile_pid() {
    local extra=''
    [ "${1:-}" != nocdp ] || extra=" -and \$_.CommandLine -notlike '*--remote-debugging-port=*'"
    "$PWSH" -NoProfile -Command \
      "$(profile_re); Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" -ErrorAction Stop | Where-Object { \$_.CommandLine -match \$re -and \$_.CommandLine -notlike '*--type=*'$extra } | Select-Object -First 1 -ExpandProperty ProcessId" \
      2>/dev/null | tr -d '\r'
}
profile_gone() { local p; p=$(profile_pid) || die "Chrome のプロセスを確認できない(powershell.exe が動かない)"; [ -z "$p" ]; }

# Windows PID のプロセスが USER_DATA_DIR の Chrome なら profile、違えばプロセス名(プロセスが無ければ空)を出す。
#   PowerShell が失敗したら非 0 を返す。
proc_kind() {
    "$PWSH" -NoProfile -Command \
      "$(profile_re); \$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$1' -ErrorAction Stop; if (\$p.Name -eq 'chrome.exe' -and \$p.CommandLine -match \$re) { 'profile' } else { \$p.Name }" \
      2>/dev/null | tr -d '\r'
}

# 127.0.0.1:PORT を LISTEN している PID(listen_pid の結果。空なら空き)が USER_DATA_DIR の Chrome でなければ、
# その説明を出す(空きか、その Chrome なら何も出さない)。$(...) で呼ぶので、失敗は呼び出し側で || exit 1 する。
#   WSL 内のプロセスが PORT を待ち受けると、wslrelay.exe が Windows の 127.0.0.1:PORT を取る(localhost 転送)。
foreign_listener() {
    local kind
    [ -n "$1" ] || return 0
    kind=$(proc_kind "$1") || die "Chrome のプロセスを確認できない(powershell.exe が動かない)"
    [ -n "$kind" ] || return 0   # プロセスがもう無い(netstat の後で閉じた)なら、待ち受けも無くなっている
    [ "$kind" != profile ] || return 0
    printf '%s' "127.0.0.1:$PORT を $USER_DATA_DIR の Chrome 以外が使っている($kind, win pid $1)"
    [ "$kind" != wslrelay.exe ] || printf '%s' "。WSL 内のプロセスが $PORT で待ち受けている(status の ssh-tunnel: 行に相手が出る)"
    echo
}

# 127.0.0.1:PORT が空いているのに USER_DATA_DIR の Chrome が残っていれば、その説明を出す(無ければ何も出さない)。
#   $(...) で呼ぶので、失敗は呼び出し側で || exit 1 する。
idle_profile() {
    local pid npid
    pid=$(profile_pid) || die "Chrome のプロセスを確認できない(powershell.exe が動かない)"
    [ -n "$pid" ] || return 0
    npid=$(profile_pid nocdp) || die "Chrome のプロセスを確認できない(powershell.exe が動かない)"
    if [ -n "$npid" ]; then
        echo "$USER_DATA_DIR の Chrome が CDP なしで起動している(win pid $npid)"
    else
        echo "$USER_DATA_DIR の Chrome が 127.0.0.1:$PORT で待ち受けずに残っている(win pid $pid)"
    fi
}

up_or_gone() { chrome_up || profile_gone; }

# 127.0.0.1:PORT を USER_DATA_DIR の Chrome 以外が使っていたら die する(空きなら何もしない)
assert_own_port() {
    local pid msg
    pid=$(listen_pid 127.0.0.1)
    msg=$(foreign_listener "$pid") || exit 1
    [ -z "$msg" ] || die "$msg"
}

start_chrome() {
    local pid msg
    [ -f "$CHROME_EXE" ] || die "Chrome が見つからない: $CHROME_EXE"
    # 同じプロファイルの Chrome が残っていると、新しい起動はそちらに引き渡されてポートが開かず、
    # ユーザーの画面にウィンドウが増えるだけになる。そのときは起動しない。
    # 閉じた直後はプロセスがしばらく残るので、消えるか、(起動中だったものが)待ち受けを始めるまで待つ。
    pid=$(profile_pid) || die "Chrome のプロセスを確認できない(powershell.exe が動かない)"
    if [ -n "$pid" ] && ! wait_for up_or_gone; then
        msg=$(idle_profile) || exit 1
        [ -z "$msg" ] || die "$msg。閉じてから start し直す"
    fi
    if chrome_up; then
        echo "chrome: running"
        return
    fi
    # 拡張機能は無効にする(拡張機能の content script が画面の書き換えに反応して、操作のたびに数秒固まったことがある)
    setsid "$CHROME_EXE" --remote-debugging-port="$PORT" --user-data-dir="$USER_DATA_DIR" --disable-extensions \
        </dev/null >/dev/null 2>&1 &
    wait_for chrome_up || die "Chrome が 127.0.0.1:$PORT で待ち受けない"
    echo "chrome: started ($USER_DATA_DIR)"
}

# Browser.close で Chrome を正常終了させる(Stop-Process だと次回「正しく終了しませんでした」が出る)
#   終了時の接続の切れ方によっては onerror になるので、node の終了コードではなく
#   127.0.0.1:PORT の LISTEN が消えたかで成否を判定する。
#   リレーや Chrome が固まっていると fetch も返らない(既定の打ち切りは 300 秒)ので、5 秒の打ち切りは最初に仕掛ける。
close_chrome() {
    node -e '
        setTimeout(() => process.exit(0), 5000);
        (async () => {
            const v = await (await fetch(process.argv[1] + "/json/version")).json();
            const ws = new WebSocket(v.webSocketDebuggerUrl);
            ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "Browser.close" }));
            ws.onmessage = ws.onclose = ws.onerror = () => process.exit(0);
        })().catch(() => process.exit(0));
    ' "http://$1:$PORT"
    # LISTEN が消えた後もプロセスはしばらく残るので、消えるまで待つ(直後の start が引き渡されないように)
    wait_for chrome_down && wait_for profile_gone
}

do_start() {
    local relay=1 ip="" again=start
    case "${1:-}" in
        '') ;;
        --no-relay) relay=0; again="start --no-relay" ;;
        *) usage ;;
    esac
    if [ "$relay" = 1 ] && is_mirrored; then
        relay=0; again=start
        echo "network: mirrored(127.0.0.1 が Windows と共通なのでリレーは立てない)"
    fi
    if [ "$relay" = 1 ]; then
        ip=$(host_ip)
        [ -n "$ip" ] || die "デフォルトゲートウェイが取得できない"
    fi
    # 中継先が Chrome でなければリレーを立てても意味が無いので、先に確かめる
    assert_own_port
    if [ "$relay" = 1 ]; then
        if relay_up "$ip"; then
            echo "relay: running on ${ip}:$PORT"
        else
            start_relay "$ip"
        fi
    fi
    if chrome_up; then
        echo "chrome: running"
    else
        start_chrome
    fi
    # リレーを立てたり残ったプロセスを待ったりしている間に、別のもの(ssh の転送を受けた wslrelay.exe など)が
    # ポートを取っていないか、もう一度確かめる
    assert_own_port
    if [ "$relay" = 0 ]; then
        wait_for win_cdp_ok || die "127.0.0.1:$PORT が CDP に応答しない(win pid $(listen_pid 127.0.0.1))。stop してから $again し直す"
        if is_mirrored; then
            wait_for cdp_ok 127.0.0.1 || die "WSL の 127.0.0.1:$PORT から CDP に届かない(mirrored)。stop してから $again し直す"
        fi
        echo "browser-url: http://127.0.0.1:$PORT (リレーは触っていない)"
        return
    fi
    wait_for cdp_ok "$ip" || die "127.0.0.1:$PORT が CDP に応答しない(win pid $(listen_pid 127.0.0.1))。stop してから $again し直す"
    echo "browser-url: http://${ip}:$PORT"
}

do_stop() {
    local ip cpid msg rc=0 mirrored=0
    if is_mirrored; then
        mirrored=1; ip=127.0.0.1   # リレーは無い。Chrome に直接繋ぐ
    else
        ip=$(host_ip)
        [ -n "$ip" ] || die "デフォルトゲートウェイが取得できない"
    fi
    trap kill_relay EXIT   # 途中で die しても、リレーは止めて終わる(下の kill_relay まで外さない)
    cpid=$(listen_pid 127.0.0.1)
    msg=$(foreign_listener "$cpid") || exit 1
    if [ -n "$msg" ]; then
        echo "chrome: $msg。閉じない"
        rc=1
    elif [ -z "$cpid" ]; then
        msg=$(idle_profile) || exit 1
        if [ -n "$msg" ]; then
            echo "chrome: $msg。CDP では閉じられない(手で閉じる)"
            rc=1
        else
            echo "chrome: not running"
        fi
    else
        # WSL の再起動後などでリレーが無いと閉じられないので、閉じる間だけ立てる
        if [ "$mirrored" = 0 ] && ! relay_up "$ip"; then
            start_relay "$ip" >/dev/null
        fi
        if close_chrome "$ip"; then
            echo "chrome: closed"
        else
            echo "chrome: Browser.close に失敗(手で閉じる)"
            rc=1
        fi
    fi
    kill_relay
    trap - EXIT
    if [ "$mirrored" = 1 ]; then
        echo "relay: not used (mirrored)"
    elif relay_up "$ip"; then
        echo "relay: 止まらない(win pid $(listen_pid "$ip"))"
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
    local ip rpid="" cpid msg ver mirrored=0; ip=$(host_ip)
    if is_mirrored; then mirrored=1; ip=127.0.0.1; echo "network: mirrored(リレー不要。127.0.0.1 を共有)"; else echo "host ip: ${ip:-?}"; fi
    tunnel_line
    mcp_line "$ip"
    [ "$mirrored" = 1 ] || { [ -z "$ip" ] || rpid=$(listen_pid "$ip"); }
    cpid=$(listen_pid 127.0.0.1)
    if [ "$mirrored" = 1 ]; then echo "relay: not used (mirrored)"
    elif [ -n "$rpid" ]; then echo "relay: running (win pid $rpid)"; else echo "relay: stopped"; fi
    msg=$(foreign_listener "$cpid") || exit 1
    if [ -n "$msg" ]; then
        echo "chrome: $msg"
    elif [ -z "$cpid" ]; then
        msg=$(idle_profile) || exit 1
        echo "chrome: ${msg:-not running}"
    elif [ "$mirrored" = 0 ] && [ -z "$rpid" ]; then
        echo "chrome: running (win pid $cpid, リレーが無いので WSL からは届かない)"
    elif ver=$(cdp_version "$ip") && [ -n "$ver" ]; then
        echo "chrome: $ver"
    else
        echo "chrome: 127.0.0.1:$PORT (win pid $cpid) が CDP に応答しない"
    fi
}

usage() {
    echo "usage: $(basename "$0") <start [--no-relay]|stop|status>" >&2
    echo "  start は Chrome を --remote-debugging-port=$PORT --user-data-dir=$USER_DATA_DIR --disable-extensions で起動する" >&2
    exit 2
}

case "${1:-}" in
    start)  [ $# -le 2 ] || usage; do_start "${2:-}" ;;
    stop)   [ $# -le 1 ] || usage; do_stop ;;
    status) [ $# -le 1 ] || usage; do_status ;;
    *) usage ;;
esac
