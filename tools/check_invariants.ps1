$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Constants = Join-Path $Root 'src\include\constants.inc'
$BootMemory = Join-Path $Root 'src\include\boot_memory.inc'
$L3Runtime = Join-Path $Root 'src\include\l3_runtime.inc'
$WindowLayout = Join-Path $Root 'src\include\window_layout.inc'
$Syscall = Join-Path $Root 'src\kernel\proc\syscall_support.inc'
$Registry = Join-Path $Root 'docs\invariant-registry.md'

function Assert-Text {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $text = Get-Content -Path $Path -Raw
    if ($text -notmatch $Pattern) { throw $Message }
}

Assert-Text $BootMemory 'APP_DATA_ADDR\s+equ\s+0x2600000' 'APP_DATA_ADDR invariant moved.'
Assert-Text $BootMemory 'APP_SLOT_SIZE\s+equ\s+0x200000' 'APP_SLOT_SIZE invariant moved.'
Assert-Text $BootMemory 'L3_SYSCALL_STACK_ADDR\s+equ\s+\(APPS_BLOB_ADDR \+ APPS_BLOB_MAX_SIZE\)' 'L3 syscall stack arena moved.'
Assert-Text $Constants 'MAX_WINDOWS\s+equ\s+APP_SLOT_COUNT' 'MAX_WINDOWS invariant changed.'
Assert-Text $Constants 'L3_USER_STACK_SIZE\s+equ\s+16384' 'L3 user stack size changed.'
Assert-Text $Constants 'L3_SYSCALL_STACK_SIZE\s+equ\s+4096' 'L3 syscall stack size changed.'

Assert-Text $L3Runtime 'L3_RT_ENTRY\s+equ\s+0' 'L3_RT_ENTRY offset changed.'
Assert-Text $L3Runtime 'L3_RT_KERNEL_RSP\s+equ\s+32' 'L3_RT_KERNEL_RSP offset changed.'
Assert-Text $L3Runtime 'L3_RT_USER_RSP\s+equ\s+48' 'L3_RT_USER_RSP offset changed.'
Assert-Text $L3Runtime 'L3_RT_USER_RIP\s+equ\s+56' 'L3_RT_USER_RIP offset changed.'
Assert-Text $L3Runtime 'L3_RT_APP_BASE\s+equ\s+72' 'L3_RT_APP_BASE offset changed.'
Assert-Text $L3Runtime 'L3_RT_SLOT\s+equ\s+120' 'L3_RT_SLOT offset changed.'
Assert-Text $L3Runtime 'L3_RT_SIZE\s+equ\s+128' 'L3_RT_SIZE changed.'

Assert-Text $Syscall 'SYSCALL_ENTRY syscall_entry\.sc_wm_list,\s+2,' 'Public syscall range changed without registry update.'
Assert-Text $Syscall 'syscall_table_count equ \(syscall_table_end - syscall_table\) / SYSCALL_ENTRY_SIZE' 'Syscall table count must be derived from table size.'
Assert-Text $Registry 'Current public syscall numbers are `0\.\.80`' 'Registry must document current syscall range.'
Assert-Text $WindowLayout 'WIN_OFF_FLAGS\s+equ\s+40' 'Window flags offset changed.'
Assert-Text $WindowLayout 'WIN_OFF_TITLE\s+equ\s+48' 'Window title offset changed.'
Assert-Text $WindowLayout 'WIN_OFF_CLICKFN\s+equ\s+128' 'Window click callback offset changed.'
Assert-Text $WindowLayout 'WIN_OFF_APPDATA\s+equ\s+136' 'Window app-data offset changed.'

Write-Host '[invariants] PASS'
