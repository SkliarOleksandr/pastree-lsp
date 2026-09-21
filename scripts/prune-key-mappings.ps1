# Remove this package's records from the IDE's Key Mappings list, and close
# the gaps that removing them leaves.
#
#   exit 0 - nothing of ours was there
#   exit 2 - removed something (and renumbered the rest)
#   exit 1 - something could not be read or written; the gaps were still
#            closed as far as possible, and the caller tells the user to look
#
# Called from uninstall.bat with %BDSVER% set by scripts\ide.bat. -DryRun
# prints what would happen and writes nothing.
#
# WHAT THE KEY IS. HKCU\Software\Embarcadero\BDS\<ver>\Editor\Options\Known
# Editor Enhancements holds one subkey per keyboard-binding module the IDE
# has ever seen, named by the module's GetName, with two values: Priority, a
# DWORD - the module's position on Tools > Options > Editor > Key Mappings -
# and Enabled, a REG_SZ "1" (a DWORD there makes the IDE skip the subkey
# silently). The IDE never removes one, so a module renamed in the plugin
# leaves its old name behind forever; eight PasTreeIdePlugin.* subkeys were
# found on 2026-09-21, seven of them dead names.
#
# WHY THE RENUMBERING IS NOT OPTIONAL. The IDE loads this list into a TList
# sized by the number of subkeys and places each module AT ITS PRIORITY. The
# first version of this cleanup deleted the eight subkeys and nothing else,
# and RAD Studio 13.2 then refused to start: "List index out of bounds (15).
# TList range is 0..7" - eight modules left, one of them (MMX) still at
# priority 15. The rule that fits everything seen that day: every Priority
# must be below the number of subkeys the IDE accepts (duplicates and gaps
# under that bound are tolerated - the IDE renumbers the live modules itself
# at startup). Renumbering the remainder to 0..N-1 in the order the user had
# satisfies it with room to spare, which is what the second half of this
# script does. The IDE was recovered by recreating the eight keys by hand
# with their old priorities and the right value types; do not make anyone
# do that again.
#
# ONLY OUR OWN NAMES. PasTreeIdePlugin.<anything> is the package's unit
# namespace and nothing else registers under it. Every other subkey is left
# alone except for its Priority, which is only ever compacted, never
# reordered.

param(
  [switch]$DryRun
)

$ver = $env:BDSVER
if ([string]::IsNullOrWhiteSpace($ver)) {
  Write-Host "scripts\prune-key-mappings.ps1: BDSVER is not set - call scripts\ide.bat first."
  exit 1
}

$base = "HKCU:\Software\Embarcadero\BDS\$ver\Editor\Options\Known Editor Enhancements"
if (-not (Test-Path -LiteralPath $base)) { exit 0 }

try {
  $modules = @(Get-ChildItem -LiteralPath $base -ErrorAction Stop | ForEach-Object {
    $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
    $prio = if ($null -ne $p.Priority) { [int]$p.Priority } else { [int]::MaxValue }
    [pscustomobject]@{ Name = $_.PSChildName; Path = $_.PSPath; Priority = $prio }
  })
}
catch {
  Write-Host "  could not read ${base}: $($_.Exception.Message)"
  exit 1
}

$ours = @($modules | Where-Object { $_.Name -like 'PasTreeIdePlugin.*' })
if ($ours.Count -eq 0) { exit 0 }

# Stable: by the priority the user had, then by name for any ties a broken
# list might hold.
$keep = @($modules | Where-Object { $_.Name -notlike 'PasTreeIdePlugin.*' } |
  Sort-Object Priority, Name)

$verb = if ($DryRun) { 'would remove' } else { 'removed' }
$failed = $false
foreach ($m in $ours) {
  try {
    if (-not $DryRun) { Remove-Item -LiteralPath $m.Path -Recurse -Force -ErrorAction Stop }
    Write-Host "  $verb key mapping record: $($m.Name)"
  }
  catch {
    Write-Host "  could not remove key mapping record $($m.Name): $($_.Exception.Message)"
    $failed = $true
  }
}

# THE COMPACTION RUNS WHATEVER HAPPENED ABOVE, over the list as it now is on
# disk - a removal that failed halfway must not leave a gap behind, because
# the gap is what stops the IDE. Only priorities change, never the order.
if (-not $DryRun) {
  try {
    $keep = @(Get-ChildItem -LiteralPath $base -ErrorAction Stop | ForEach-Object {
      $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
      $prio = if ($null -ne $p.Priority) { [int]$p.Priority } else { [int]::MaxValue }
      [pscustomobject]@{ Name = $_.PSChildName; Path = $_.PSPath; Priority = $prio }
    } | Sort-Object Priority, Name)
  }
  catch {
    Write-Host "  could not re-read ${base}: $($_.Exception.Message)"
    $failed = $true
  }
}
$i = 0
$renumbered = 0
foreach ($m in $keep) {
  if ($m.Priority -ne $i) {
    try {
      if (-not $DryRun) {
        Set-ItemProperty -LiteralPath $m.Path -Name Priority -Value $i -Type DWord -ErrorAction Stop
      }
      $renumbered++
    }
    catch {
      Write-Host "  could not set the priority of $($m.Name): $($_.Exception.Message)"
      $failed = $true
    }
  }
  $i++
}
if ($renumbered -gt 0) {
  $verb2 = if ($DryRun) { 'would renumber' } else { 'renumbered' }
  Write-Host "  $verb2 $renumbered of $($keep.Count) remaining key mapping modules to 0..$($keep.Count - 1)"
}

if ($failed) {
  Write-Host "  CHECK the Key Mappings list before starting the IDE: every module under"
  Write-Host "  $base"
  Write-Host "  must have a distinct Priority in 0..N-1, or RAD Studio does not start."
  exit 1
}
exit 2
