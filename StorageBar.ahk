#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ストレージの空き容量をタスクバーの左端に常時表示する

; ===== 設定 =====
UPDATE_MS  := 30000   ; 容量を取り直す間隔
WATCH_MS   := 1000    ; 位置合わせ・最前面維持の間隔
COLOR_MS   := 10000   ; 背景色を拾い直す間隔 (PixelGetColor は 1 回 17ms 待たされるので低頻度にする)
WARN_PCT   := 20      ; 空き率がこれ未満ならオレンジ
DANGER_PCT := 10      ; 空き率がこれ未満なら赤
BLOCK_W    := 116     ; 1ドライブ分の幅 (96dpi 基準)
GAP        := 8       ; タスクバー左端からの余白 (96dpi 基準)
LINK_PATH  := A_Startup "\StorageBar.lnk"

scale  := A_ScreenDPI / 96
drives := ""
bg     := "202020"   ; タスクバーから拾った背景色
bar    := ""
blocks := []
hideStreak := 0      ; 非表示判定が連続した回数
evHooks    := []     ; SetWinEventHook のハンドル
evCb       := 0      ; コールバックの参照（解放すると落ちるので保持する）

TraySetIcon("shell32.dll", 9)
BuildMenu()
Refresh()
SampleBg()
SetTimer(Refresh, UPDATE_MS)
SetTimer(Watch, WATCH_MS)
SetTimer(SampleBg, COLOR_MS)

; 前面ウィンドウが切り替わる瞬間にタスクバーが z 順で持ち上げられてバーが隠れるため、
; 1 秒周期を待たずにその場で押し戻す（ポーリングは取りこぼし用の保険として残す）
evCb := CallbackCreate(OnWinEvent, , 7)
; WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
for ev in [0x0003, 0x0016, 0x0017] {   ; FOREGROUND, MINIMIZESTART, MINIMIZEEND
    h := DllCall("SetWinEventHook", "uint", ev, "uint", ev, "ptr", 0, "ptr", evCb
        , "uint", 0, "uint", 0, "uint", 0x0002, "ptr")
    if h
        evHooks.Push(h)
}
OnExit(Cleanup)

; ===== 容量の更新 =====
Refresh(*) {
    global drives
    newDrives := DriveGetList("FIXED")
    if newDrives != drives {
        drives := newDrives
        BuildGui()
    }

    tip := ""
    for b in blocks {
        try {
            free  := DriveGetSpaceFree(b.drive ":\")
            total := DriveGetCapacity(b.drive ":\")
        } catch {
            b.text.Value := b.drive ": --"
            b.prog.Value := 0
            b.pct := 100
            tip .= b.drive ": 取得失敗`n"
            continue
        }
        b.pct := total ? free / total * 100 : 0
        b.text.Value := Format("{}: {} / {} GB", b.drive, Gb(free), Gb(total))
        b.prog.Value := Round(100 - b.pct)  ; バーは使用率
        tip .= Format("{}:  空き {} GB / {} GB ({:.1f}%)`n", b.drive, Gb(free), Gb(total), b.pct)
    }
    A_IconTip := RTrim(tip, "`n")
    ApplyColors()
    Watch()
}

; 空き率に応じて文字とバーの色を変える
ApplyColors() {
    c := Colors()
    bar.BackColor := bg
    for b in blocks {
        level := b.pct < DANGER_PCT ? c.danger : b.pct < WARN_PCT ? c.warn : ""
        b.text.SetFont("c" (level || c.fg))
        b.prog.Opt("c" (level || c.ok) " Background" c.track)
    }
}

; MB → GB 表記（エクスプローラーと同じ 1024 進）
Gb(mb) {
    gb := mb / 1024
    return gb < 100 ? Format("{:.1f}", gb) : Round(gb)
}

; 背景の明るさで文字色の組を選ぶ（テーマ設定ではなく実際の色で判断）
Colors() {
    n := Integer("0x" bg)
    lum := 0.299 * (n >> 16 & 0xFF) + 0.587 * (n >> 8 & 0xFF) + 0.114 * (n & 0xFF)
    if lum > 140
        return {fg: "1A1A1A", track: "C8C8C8", ok: "0067C0", warn: "CA5010", danger: "C42B1C"}
    return {fg: "FFFFFF", track: "454545", ok: "4CC2FF", warn: "FFB900", danger: "FF6060"}
}

; ===== 表示ウィンドウ =====
BuildGui() {
    global bar, blocks
    if IsObject(bar)
        bar.Destroy()
    c := Colors()
    ; WS_EX_NOACTIVATE: クリックしてもフォーカスを奪わない
    bar := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "StorageBar")
    bar.BackColor := bg
    bar.MarginX := 0, bar.MarginY := 0
    bar.SetFont("s9 c" c.fg, "Segoe UI")
    bar.OnEvent("ContextMenu", (*) => A_TrayMenu.Show())

    blocks := []
    w := Round(BLOCK_W * scale)
    pad := Round(10 * scale)
    for i, d in StrSplit(drives) {
        x := (i - 1) * w
        t := bar.AddText(Format("x{} y{} w{} h{} Center", x, Round(4 * scale), w, Round(20 * scale)))
        p := bar.AddProgress(Format("x{} y{} w{} h{} Smooth Background{}", x + pad, Round(27 * scale), w - pad * 2, Round(4 * scale), c.track))
        t.OnEvent("DoubleClick", OpenPC)
        blocks.Push({drive: d, text: t, prog: p, pct: 100})
    }
}

; タスクバーに合わせて位置を直し、最前面に戻す
Watch() {
    global hideStreak
    if !IsObject(bar) || !blocks.Length
        return
    tb := WinExist("ahk_class Shell_TrayWnd")
    ; 一時的な誤判定で消えないよう、非表示は判定が 2 回続いてから（表示側は即時）
    if !tb || ShouldHide(tb) {
        if ++hideStreak >= 2
            bar.Hide()
        return
    }
    hideStreak := 0
    ; Explorer 再起動中や画面ロック中は失敗しうるので、その回は諦めて次の周期に任せる
    try {
        WinGetPos(&tx, &ty, &tw, &th, tb)
        w := Round(BLOCK_W * scale) * blocks.Length
        h := Round(36 * scale)
        x := tx + Round(GAP * scale)
        y := ty + (th - h) // 2
        ; Shell_TrayWnd の直上に挿入してはいけない (Win11 はその上にもう一枚 CoreWindow を重ねて
        ; タスクバーを描くので、その下に潜って見えなくなる)。最前面の先頭に置き直す。
        ; HWND_TOPMOST, SWP_NOACTIVATE | SWP_SHOWWINDOW
        DllCall("SetWindowPos", "ptr", bar.Hwnd, "ptr", -1, "int", x, "int", y, "int", w, "int", h, "uint", 0x0050)
    }
}

; イベントは連続して飛んでくるので、ワンショットタイマーで 1 回に畳む
; SetTimer は関数ごとに 1 本なので、Watch 本体ではなく別関数で張る
; (Watch に直接張ると WATCH_MS の定期実行がワンショットに置き換わって止まる)
OnWinEvent(hook, event, hwnd, obj, child, thread, time) {
    SetTimer(Nudge, -30)
}

Nudge() {
    Watch()
}

Cleanup(*) {
    for h in evHooks
        DllCall("UnhookWinEvent", "ptr", h)
    if evCb
        CallbackFree(evCb)
}

; タスクバー左端の余白の色を拾って背景をなじませる
; PixelGetColor は画面 DC の読み取りで DWM の合成待ちが入り 1 回 17ms ブロックするため、
; 位置合わせとは分けて低頻度で呼ぶ（色が変わるのはテーマ・アクセント変更時だけ）
SampleBg() {
    global bg
    if !IsObject(bar) || !blocks.Length
        return
    if !DllCall("IsWindowVisible", "ptr", bar.Hwnd)   ; 非表示中は拾っても意味がない
        return
    tb := WinExist("ahk_class Shell_TrayWnd")
    if !tb
        return
    try {
        WinGetPos(&tx, &ty, , &th, tb)
        h := Round(36 * scale)
        y := ty + (th - h) // 2
        CoordMode("Pixel", "Screen")
        col := SubStr(PixelGetColor(tx + Round(GAP * scale / 2), y + h // 2), 3)
        if col != bg {
            bg := col
            ApplyColors()
        }
    }
}

; タスクバーが隠れている時や、全画面アプリが前面にある時は表示しない
ShouldHide(tb) {
    try {
        WinGetPos(, &ty, , , tb)
        if ty >= A_ScreenHeight - 4
            return true
        fg := WinExist("A")
        if !fg || fg = tb || fg = bar.Hwnd
            return false
        cls := WinGetClass(fg)
        if cls = "Progman" || cls = "WorkerW"
            return false
        ; 最大化・最小化したウィンドウは全画面ではない
        ; (Win11 の最大化は不可視の枠のぶん画面より大きく見えるので、位置とサイズでは区別できない)
        if WinGetMinMax(fg)
            return false
        ; 生成直後や DWM で cloaked なウィンドウは、まだ何も描いていないので無視する
        if !DllCall("IsWindowVisible", "ptr", fg)
            return false
        if !DllCall("dwmapi\DwmGetWindowAttribute", "ptr", fg, "uint", 14, "uint*", &cloaked := 0, "uint", 4) && cloaked
            return false
        WinGetPos(&x, &y, &w, &h, fg)
        return x <= 0 && y <= 0 && w >= A_ScreenWidth && h >= A_ScreenHeight
    }
    return false
}

; ===== メニュー =====
BuildMenu() {
    m := A_TrayMenu
    m.Delete()
    m.Add("今すぐ更新", Refresh)
    m.Add("PCを開く", OpenPC)
    m.Add()
    m.Add("スタートアップに登録", ToggleStartup)
    m.Add()
    m.Add("終了", (*) => ExitApp())
    m.Default := "PCを開く"
    UpdateStartupCheck()
}

OpenPC(*) {
    Run("explorer.exe shell:MyComputerFolder")
}

ToggleStartup(*) {
    if FileExist(LINK_PATH)
        FileDelete(LINK_PATH)
    else
        FileCreateShortcut(A_AhkPath, LINK_PATH, A_ScriptDir, '"' A_ScriptFullPath '"')
    UpdateStartupCheck()
}

UpdateStartupCheck() {
    if FileExist(LINK_PATH)
        A_TrayMenu.Check("スタートアップに登録")
    else
        A_TrayMenu.Uncheck("スタートアップに登録")
}
