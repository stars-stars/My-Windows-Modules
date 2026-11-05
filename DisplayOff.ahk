#Requires AutoHotkey v2.0
#SingleInstance Force

; Win + Backspace で画面を暗転する（ロックしない疑似消灯）
;
; モダンスタンバイ機（Surface など）では SC_MONITORPOWER で本当にディスプレイを消すと
; スリープと同じ扱いになり、サインイン設定によってはロックされる。
; そこで本当には消灯せず、全画面の黒いウィンドウを出して明るさを 0 にする。
; キーかマウスを操作すると元に戻る。

; トレイアイコン: 月マーク付きモニター（ディスプレイのスリープ）
try TraySetIcon("imageres.dll", 97)
A_IconTip := "DisplayOff`nWin + Backspace: 画面を暗転（ロックなし）"

; フックを入れると A_TimeIdlePhysical が物理的な入力だけを数えるようになる
InstallKeybdHook()
InstallMouseHook()

global blanked := false        ; 暗転中か
global blackGui := ""          ; 黒い全画面ウィンドウ
global savedBrightness := ""   ; 暗転前の明るさ（取得できなかったら空）
global prevWin := 0            ; 暗転前のアクティブウィンドウ
global lastIdle := 0           ; 前回チェック時の A_TimeIdlePhysical

OnExit((*) => Restore())

#Backspace:: {
    global blanked, blackGui, savedBrightness, prevWin, lastIdle

    ; キーを離すまで待機して、離したときの入力ですぐ復帰しないようにする
    KeyWait("Backspace")
    KeyWait("LWin")
    KeyWait("RWin")
    Sleep(200)

    if blanked
        return
    blanked := true
    prevWin := WinExist("A")

    ; 内蔵ディスプレイの明るさを保存して 0 にする（非対応でも黒画面は出す）
    savedBrightness := GetBrightness()
    if savedBrightness != ""
        SetBrightness(0)

    ; 仮想スクリーン全体（全モニター）を覆う黒いウィンドウ
    x := SysGet(76), y := SysGet(77), w := SysGet(78), h := SysGet(79)
    blackGui := Gui("+AlwaysOnTop -Caption +ToolWindow")
    blackGui.BackColor := "000000"
    ; アクティブにして表示し、復帰時に押したキーが裏のアプリに入らないようにする
    blackGui.Show("x" x " y" y " w" w " h" h)
    DllCall("ShowCursor", "Int", false)

    lastIdle := A_TimeIdlePhysical
    SetTimer(CheckInput, 100)
}

; 物理的な入力があったら（アイドル時間が前回より短くなったら）復帰する
CheckInput() {
    global lastIdle
    idle := A_TimeIdlePhysical
    if idle < lastIdle
        Restore()
    else
        lastIdle := idle
}

Restore() {
    global blanked, blackGui, savedBrightness, prevWin
    if !blanked
        return
    SetTimer(CheckInput, 0)

    if savedBrightness != ""
        SetBrightness(savedBrightness)
    DllCall("ShowCursor", "Int", true)
    try blackGui.Destroy()
    blackGui := ""

    if prevWin && WinExist(prevWin)
        try WinActivate(prevWin)
    blanked := false
}

; 内蔵ディスプレイの明るさ（0-100）。取得できなければ空文字
GetBrightness() {
    try {
        wmi := ComObjGet("winmgmts:\\.\root\WMI")
        for m in wmi.ExecQuery("SELECT CurrentBrightness FROM WmiMonitorBrightness WHERE Active=TRUE")
            return m.CurrentBrightness
    }
    return ""
}

SetBrightness(level) {
    try {
        wmi := ComObjGet("winmgmts:\\.\root\WMI")
        for m in wmi.ExecQuery("SELECT * FROM WmiMonitorBrightnessMethods WHERE Active=TRUE")
            m.WmiSetBrightness(1, level)
    }
}
