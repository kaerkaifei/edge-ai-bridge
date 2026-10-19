' ============================================================
'  silent.vbs — 零闪窗启动器
'
'  为什么需要这个：用 .ps1 直接双击/命令行启动时，Windows 会
'  先弹一个黑色控制台窗口出来再执行，这一下"闪"就已经打扰人了。
'  用 wscript.exe 跑 VBS 不会创建控制台，再由它去调 PowerShell，
'  全程没有任何窗口出现。
'
'  用法：双击，或在命令行执行
'        wscript.exe launcher\silent.vbs
' ============================================================

Option Explicit

Dim shell, fso, here, ps1, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 本文件所在目录（launcher\），再往上一层是仓库根
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "launch_hidden.ps1")

If Not fso.FileExists(ps1) Then
    MsgBox "找不到 launch_hidden.ps1：" & ps1, 16, "Edge AI Bridge"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

' 0 = 隐藏窗口，False = 不等待
shell.Run cmd, 0, False
