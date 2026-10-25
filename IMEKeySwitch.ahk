#Requires AutoHotkey v2.0
#SingleInstance Force

; 変換 / 無変換キーを IME の ON / OFF 専用キーにする

LINK_PATH := A_Startup "\IMEKeySwitch.lnk"

; トレイで見分けやすいよう IME 用のアイコンにする (input.dll = テキストサービス)
try TraySetIcon("input.dll", 1)
BuildMenu()

; 変換 → IME ON（ひらがな）
sc079::Send "{vk16}"

; 無変換 → IME OFF（半角英数字）
sc07B::Send "{vk1A}"

; ===== メニュー =====
BuildMenu() {
    m := A_TrayMenu
    m.Delete()
    m.Add("スタートアップに登録", ToggleStartup)
    m.Add()
    m.Add("終了", (*) => ExitApp())
    A_IconTip := "IMEKeySwitch`n変換: IME ON / 無変換: IME OFF"
    UpdateStartupCheck()
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
