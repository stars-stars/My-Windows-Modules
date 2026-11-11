#Requires AutoHotkey v2.0
#SingleInstance Force

; PowerPoint の編集画面で
;   ・Shift + ホイール  → スクロール量を fastScrollAmount 倍にする
;   ・ミドルボタン      → オートスクロール（短いクリックで固定、長押しドラッグで一時的）
; スクロールはホイール入力の合成で行う。カーソル下のウィンドウが受け取るため、
; ペイン構造・ビュー種別・フォーカス位置に依存しない。COM は使わない。

; ===== 設定（変更したら Ctrl + Alt + R） =====
cfg := {
    fastScrollAmount: 8,    ; Shift + ホイール1刻みを何刻みにするか
    releaseShift: true,     ; 合成ホイールから Shift 修飾を外す（挙動が変なら false）
    deadZone: 24,           ; 原点からこのpx以内はスクロールしない
    accelPx: 48,            ; 何px離れるごとに速度を1段階増やすか
    maxSpeed: 10,           ; 各軸の最大速度
    scrollPeriod: 110,      ; 速度1で1刻み送る間隔（ms）
    tickInterval: 16,       ; 位置確認とスクロールの間隔（ms）
    horizontal: true,       ; 横方向のオートスクロールを行うか
    markerSize: 28,         ; 原点マーカーの直径（px）
    stickyHoldTime: 700,    ; この時間以内に離せば固定モードを継続（ms）
    stickyMovePx: 60        ; この距離以内の動きなら「クリック」とみなす（px）
}

; 状態はこのオブジェクトに集約する。
state := {
    scrolling: false, originX: 0, originY: 0, targetHwnd: 0, marker: 0,
    pressTick: 0, lastTick: 0, lastInject: 0,
    carryX: 0, carryY: 0, dirX: 0, dirY: 0
}

CoordMode("Mouse", "Screen")
OnExit(CleanupOnExit)
ValidateSettings()
A_IconTip := "PowerPoint FastScroll"

; 対象は編集画面（PPTFrameClass）のみ。
; スライドショー（screenClass）はホイール1刻み＝1スライドなので触らない。
#HotIf WinActive("ahk_class PPTFrameClass") || state.scrolling
*MButton:: OnMButtonDown()
*MButton Up:: OnMButtonUp()

; オートスクロール中のみ有効。通常時の Esc やクリックは元の動作のまま。
#HotIf state.scrolling
*Esc:: StopAutoScroll()
~*LButton:: StopAutoScroll()
~*RButton:: StopAutoScroll()
; `*` を付けない＝Shift + ホイールはこの停止用ホットキーに取られない。
~WheelUp:: OnUserWheel()
~WheelDown:: OnUserWheel()

#HotIf WinActive("ahk_class PPTFrameClass")
+WheelUp:: FastScroll(1)
+WheelDown:: FastScroll(-1)

#HotIf
^!r:: ReloadScript()

ValidateSettings() {
    global cfg
    if (cfg.fastScrollAmount < 1 || cfg.fastScrollAmount != Floor(cfg.fastScrollAmount)
        || cfg.deadZone < 0 || cfg.accelPx <= 0
        || cfg.maxSpeed < 1 || cfg.maxSpeed != Floor(cfg.maxSpeed)
        || cfg.scrollPeriod <= 0
        || cfg.tickInterval < 1 || cfg.tickInterval != Floor(cfg.tickInterval)
        || cfg.markerSize < 8 || cfg.stickyHoldTime < 0 || cfg.stickyMovePx < 0)
        throw ValueError("設定値を確認してください。間隔・加速・最大速度は正の値です。")
}

; ホイール入力を合成する。notches は符号付き（垂直は正で上、水平は正で右）。
; dwExtraInfo に KEY_IGNORE を入れるのが重要。これが無いと AHK 自身のフックが
; 合成イベントをユーザー操作と見なし、停止用ホットキーや +WheelUp が再帰発火する。
SendWheel(axis, notches) {
    global state
    static WHEEL := 0x0800, HWHEEL := 0x1000 ; MOUSEEVENTF_WHEEL / _HWHEEL
    static KEY_IGNORE := 0xFFC3D44F          ; AHK が無視する dwExtraInfo
    if !notches
        return
    flag := axis = "V" ? WHEEL : HWHEEL
    delta := notches > 0 ? 120 : -120
    state.lastInject := A_TickCount
    ; 1回で 120*n を渡さない。符号だけを見るアプリでも n 刻み分動かすため。
    loop Abs(notches)
        DllCall("User32\mouse_event", "UInt", flag, "Int", 0, "Int", 0,
            "Int", delta, "UPtr", KEY_IGNORE)
}

; 停止はユーザーが回したホイールだけに反応させる。KEY_IGNORE が効かない環境でも
; 直前の合成分を取り違えないよう、送信直後の短い猶予を設ける。
OnUserWheel() {
    global state
    if (A_TickCount - state.lastInject > 60)
        StopAutoScroll()
}

; カーソルの下が対象の PowerPoint ウィンドウかどうか。
; WindowFromPoint は WS_EX_TRANSPARENT のマーカーを無視するので判定を邪魔しない。
IsTargetUnderCursor(hwnd) {
    if !hwnd
        return false
    MouseGetPos(, , &win)
    if !win
        return false
    return DllCall("User32\GetAncestor", "Ptr", win, "UInt", 2, "Ptr") = hwnd
}

FastScroll(direction) {
    global cfg, state
    if state.scrolling
        StopAutoScroll()
    hwnd := WinActive("ahk_class PPTFrameClass")
    ; マウス下が別アプリならホイールを送らない。
    if !IsTargetUnderCursor(hwnd)
        return
    ; Shift を押したままだと合成ホイールにも MK_SHIFT が乗り、
    ; PowerPoint 側で別の動作（横移動など）になりうる。
    ; 物理キーは操作せず、論理状態だけ一時的に解放して必ず戻す。
    restore := false
    if (cfg.releaseShift && GetKeyState("Shift", "P")) {
        SendEvent("{Blind}{Shift up}")
        restore := true
    }
    try {
        SendWheel("V", direction * cfg.fastScrollAmount)
    } finally {
        if (restore && GetKeyState("Shift", "P"))
            SendEvent("{Blind}{Shift down}")
    }
}

OnMButtonDown() {
    global state
    if state.scrolling {
        StopAutoScroll() ; 固定モードの解除
        return
    }
    StartAutoScroll()
}

; 短いクリックは固定モード、動かした／長く押したなら離した時点で停止。
OnMButtonUp() {
    global cfg, state
    if !state.scrolling
        return
    MouseGetPos(&x, &y)
    moved := Abs(x - state.originX) > cfg.stickyMovePx
        || Abs(y - state.originY) > cfg.stickyMovePx
    if (moved || A_TickCount - state.pressTick > cfg.stickyHoldTime)
        StopAutoScroll()
}

StartAutoScroll() {
    global cfg, state
    hwnd := WinActive("ahk_class PPTFrameClass")
    if !hwnd
        return
    MouseGetPos(&x, &y)
    state.originX := x
    state.originY := y
    state.targetHwnd := hwnd
    state.pressTick := state.lastTick := A_TickCount
    state.carryX := state.carryY := 0
    state.dirX := state.dirY := 0
    state.scrolling := true
    ; マーカーは目印なので、作れなくてもスクロールは続行する。
    try ShowMarker()
    SetTimer(AutoScrollTick, cfg.tickInterval)
}

AxisSpeed(delta) {
    global cfg
    distance := Abs(delta)
    if (distance <= cfg.deadZone)
        return 0
    speed := Min(Floor((distance - cfg.deadZone) / cfg.accelPx) + 1, cfg.maxSpeed)
    return delta < 0 ? -speed : speed
}

AutoScrollTick() {
    global cfg, state
    if !state.scrolling
        return
    if !WinActive("ahk_id " state.targetHwnd) {
        StopAutoScroll()
        return
    }
    ; 遅延時に大量のスクロールをまとめて発生させない。
    now := A_TickCount
    elapsed := Min(Max(now - state.lastTick, 0), 50)
    state.lastTick := now
    ; カーソルが他アプリの上にある間は送らない。戻れば再開する。
    if !IsTargetUnderCursor(state.targetHwnd)
        return
    MouseGetPos(&x, &y)
    vy := AxisSpeed(y - state.originY)
    vx := cfg.horizontal ? AxisSpeed(x - state.originX) : 0
    sx := vx = 0 ? 0 : (vx > 0 ? 1 : -1)
    sy := vy = 0 ? 0 : (vy > 0 ? 1 : -1)
    ; 方向が変わった軸は端数を捨てる。
    if (sx != state.dirX)
        state.carryX := 0
    if (sy != state.dirY)
        state.carryY := 0
    state.dirX := sx
    state.dirY := sy
    state.carryX += Abs(vx) * elapsed / cfg.scrollPeriod
    state.carryY += Abs(vy) * elapsed / cfg.scrollPeriod
    stepsX := Floor(state.carryX)
    stepsY := Floor(state.carryY)
    state.carryX -= stepsX
    state.carryY -= stepsY
    ; 下へ動かしたら下へスクロール＝ホイールは負方向。
    SendWheel("V", -sy * stepsY)
    SendWheel("H", sx * stepsX)
}

ShowMarker() {
    global cfg, state
    size := cfg.markerSize
    ; WS_EX_NOACTIVATE + WS_EX_TRANSPARENT。フォーカスを奪わず、
    ; 合成ホイールやクリックを吸わない（これが無いと原点付近で効かなくなる）。
    marker := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020",
        "PowerPoint AutoScroll Marker")
    state.marker := marker ; 途中で失敗しても StopAutoScroll で破棄できる
    marker.BackColor := "303030"
    marker.MarginX := marker.MarginY := 0
    marker.Show("NA"
        . " x" Round(state.originX - size / 2)
        . " y" Round(state.originY - size / 2)
        . " w" size " h" size)
    WinSetRegion("0-0 w" size " h" size " E", marker) ; 円形に切り抜く
    WinSetTransparent(165, marker)
}

StopAutoScroll() {
    global state
    state.scrolling := false
    SetTimer(AutoScrollTick, 0)
    if IsObject(state.marker)
        try state.marker.Destroy()
    state.marker := 0
    state.targetHwnd := 0
    state.carryX := state.carryY := 0
    state.dirX := state.dirY := 0
}

ReloadScript() {
    StopAutoScroll()
    Reload()
}

CleanupOnExit(*) {
    StopAutoScroll()
    return 0
}
