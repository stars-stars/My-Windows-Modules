#Requires AutoHotkey v2.0
#SingleInstance Force

; Win + Backspace でディスプレイをオフ
#Backspace:: {
    ; キーを離すまで待機して再点灯を防ぐ
    KeyWait("Backspace")
    KeyWait("LWin")
    KeyWait("RWin")
    Sleep(200)

    ; ディスプレイをオフにする
    SendMessage(0x0112, 0xF170, 2, , "Program Manager")
}

