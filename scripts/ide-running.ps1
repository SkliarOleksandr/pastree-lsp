# Is the RAD Studio named by %BDSROOT% running?
#
#   exit 0 - no
#   exit 2 - yes
#   exit 1 - cannot tell (which the caller must treat as "yes")
#
# IN A SCRIPT FILE RATHER THAN INLINE IN THE .BAT, and that is the whole point
# of this file existing. The inline version - powershell -Command "... | Where-
# Object { $_.Path ... }" inside a cmd for/f - silently lost the automatic
# variable: it reported zero running IDEs while one was plainly open, and every
# outward sign said the check had run and passed. A guard that fails open, with
# no error, is worse than no guard. A -File call passes no expression through
# cmd's parser at all, so there is nothing left to be eaten.
#
# Communicating by EXIT CODE rather than by printing a number for the caller to
# parse, for the same reason: a parse is another place for the answer to
# quietly become "0".

$root = $env:BDSROOT
if ([string]::IsNullOrWhiteSpace($root)) { exit 1 }

try {
  $running = @(Get-Process -Name bds -ErrorAction SilentlyContinue)
}
catch {
  exit 1
}

# A process whose path cannot be read - an IDE running elevated, say - counts
# as a match. "Cannot tell" is not "absent", and the safe reading of it is to
# stop rather than overwrite a file someone may have open.
$mine = @($running | Where-Object {
  (-not $_.Path) -or
  $_.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
})

if ($mine.Count -gt 0) { exit 2 }
exit 0
