#requires -Version 5.1
<#
  apply-changes.ps1

  Назначение:
    Папка C:\VacationDashboard является источником для сборки Docker-образа,
    в ней же лежит рабочая БД (data\vacation.db) и её может править внешний
    разработчик. В проекте нет системы контроля версий, поэтому скрипт ведёт
    собственный "эталон" — снимок исходников в том виде, в каком они были
    успешно применены (собраны в контейнер) в прошлый раз.

  Что делает:
    а) проверяет, какие файлы изменились относительно эталона;
    б) показывает по ним построчный diff;
    в) запрашивает подтверждение и, если да, делает резервную копию БД,
       пересобирает и перезапускает контейнер, затем обновляет эталон.

  Использование:
    .\apply-changes.ps1                 # проверить, показать, спросить, применить
    .\apply-changes.ps1 -Check          # только проверить и показать (ничего не менять)
    .\apply-changes.ps1 -Yes            # без вопроса (для автоматизации)
    .\apply-changes.ps1 -Reinit         # пересоздать эталон из текущего состояния
    .\apply-changes.ps1 -Message "..."  # комментарий для журнала

  Эталон хранится в .codewhale\baseline и в сборку/образ не попадает.
#>
[CmdletBinding()]
param(
  [switch]$Check,
  [switch]$Yes,
  [switch]$Reinit,
  [string]$Message = ""
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Here     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-Location $Here

$StateDir = Join-Path $Here ".codewhale"
$Baseline = Join-Path $StateDir "baseline"
$LogFile  = Join-Path $StateDir "apply.log"

# Каталоги и файлы, которые не являются исходниками и не отслеживаются.
$ExcludeDirs  = @("data", ".codewhale", "__pycache__", ".git", ".venv", "venv", "node_modules")
$ExcludeNames = @("*.db", "*.db-wal", "*.db-shm", "*.bak", "*.pyc", "*.log", "*.tmp")
$BinaryExt    = @(".db", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip", ".7z", ".pdf",
                  ".woff", ".woff2", ".ttf", ".eot", ".exe", ".dll", ".so", ".bin")

$MaxDiffLines = 800   # максимум строк diff на один файл
$MaxLcsCells  = 250000 # предел для точного LCS-диффа (иначе показываем блоками)

# ------------------------------------------------------------------ утилиты

function Fail([string]$Text) {
  Write-Host "ОШИБКА: $Text" -ForegroundColor Red
  exit 1
}

function Get-TrackedFiles([string]$Root) {
  # Возвращает относительные пути отслеживаемых файлов, не заходя
  # в исключённые каталоги (data, .codewhale и т.п.).
  $result = New-Object System.Collections.Generic.List[string]
  $stack  = New-Object System.Collections.Stack
  $stack.Push("")
  while ($stack.Count -gt 0) {
    $relDir = [string]$stack.Pop()
    $full   = if ($relDir) { Join-Path $Root $relDir } else { $Root }
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($d in Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue) {
      if ($ExcludeDirs -contains $d.Name) { continue }
      $childRel = if ($relDir) { Join-Path $relDir $d.Name } else { $d.Name }
      $stack.Push($childRel)
    }
    foreach ($f in Get-ChildItem -LiteralPath $full -File -Force -ErrorAction SilentlyContinue) {
      $skip = $false
      foreach ($pat in $ExcludeNames) { if ($f.Name -like $pat) { $skip = $true; break } }
      if ($skip) { continue }
      $childRel = if ($relDir) { Join-Path $relDir $f.Name } else { $f.Name }
      $result.Add($childRel)
    }
  }
  return $result
}

function Get-FileText([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $c = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue
  if ($null -eq $c) { return @() }
  return @($c)
}

function Test-IsText([string]$Path) {
  $ext = [System.IO.Path]::GetExtension($Path).ToLower()
  if ($BinaryExt -contains $ext) { return $false }
  $len = (Get-Item -LiteralPath $Path).Length
  if ($len -eq 0) { return $true }
  if ($len -gt 2MB) { return $false }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  foreach ($b in $bytes) { if ($b -eq 0) { return $false } }
  return $true
}

function Get-UnifiedDiff([string[]]$Old, [string[]]$New, [string]$OldName, [string]$NewName) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("--- $OldName")
  [void]$sb.AppendLine("+++ $NewName")

  if ($null -eq $Old) { $Old = @() }
  if ($null -eq $New) { $New = @() }

  # Отбрасываем общий префикс и суффикс — точный LCS нужен только на "середине".
  $minLen = [Math]::Min($Old.Count, $New.Count)
  $pre = 0
  while ($pre -lt $minLen -and $Old[$pre] -ceq $New[$pre]) { $pre++ }
  $suf = 0
  while ($suf -lt ($minLen - $pre) -and
         $Old[$Old.Count - 1 - $suf] -ceq $New[$New.Count - 1 - $suf]) { $suf++ }

  $oldCount = $Old.Count - $pre - $suf
  $newCount = $New.Count - $pre - $suf
  if ($oldCount -gt 0) { $midOld = @($Old[$pre..($pre + $oldCount - 1)]) } else { $midOld = @() }
  if ($newCount -gt 0) { $midNew = @($New[$pre..($pre + $newCount - 1)]) } else { $midNew = @() }

  $m = $midOld.Count
  $n = $midNew.Count

  if (($m * $n) -le $MaxLcsCells) {
    $dp = New-Object 'int[,]' ($m + 1), ($n + 1)
    for ($i = $m - 1; $i -ge 0; $i--) {
      for ($j = $n - 1; $j -ge 0; $j--) {
        if ($midOld[$i] -ceq $midNew[$j]) { $dp[$i, $j] = $dp[($i + 1), ($j + 1)] + 1 }
        else {
          $down  = $dp[($i + 1), $j]
          $right = $dp[$i, ($j + 1)]
          $dp[$i, $j] = [Math]::Max($down, $right)
        }
      }
    }
    $i = 0; $j = 0
    while ($i -lt $m -and $j -lt $n) {
      if ($midOld[$i] -ceq $midNew[$j]) { [void]$sb.AppendLine(" " + $midOld[$i]); $i++; $j++ }
      elseif ($dp[($i + 1), $j] -ge $dp[$i, ($j + 1)]) { [void]$sb.AppendLine("-" + $midOld[$i]); $i++ }
      else { [void]$sb.AppendLine("+" + $midNew[$j]); $j++ }
    }
    while ($i -lt $m) { [void]$sb.AppendLine("-" + $midOld[$i]); $i++ }
    while ($j -lt $n) { [void]$sb.AppendLine("+" + $midNew[$j]); $j++ }
  }
  else {
    foreach ($l in $midOld) { [void]$sb.AppendLine("-" + $l) }
    foreach ($l in $midNew) { [void]$sb.AppendLine("+" + $l) }
  }

  $lines = $sb.ToString() -split "`r?`n"
  if ($lines.Count -gt $MaxDiffLines) {
    $shown = $lines[0..($MaxDiffLines - 1)]
    return (($shown -join "`r`n") + "`r`n... (diff обрезан: всего строк $($lines.Count))")
  }
  return $sb.ToString().TrimEnd("`r", "`n")
}

function Write-Log([string]$Text) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Update-Baseline {
  if (Test-Path -LiteralPath $Baseline) { Remove-Item -LiteralPath $Baseline -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Baseline | Out-Null
  foreach ($rel in Get-TrackedFiles $Here) {
    $src = Join-Path $Here $rel
    $dst = Join-Path $Baseline $rel
    $dir = Split-Path -Parent $dst
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}

# ------------------------------------------------------------------ эталон

if ($Reinit) {
  Update-Baseline
  Write-Host "Эталон пересоздан из текущего состояния: $Baseline" -ForegroundColor Green
  Write-Log "Эталон пересоздан вручную"
  exit 0
}

if (-not (Test-Path -LiteralPath $Baseline) -or
    -not (Get-ChildItem -LiteralPath $Baseline -Recurse -File -Force -ErrorAction SilentlyContinue)) {
  Update-Baseline
  Write-Host "Эталон не найден. Создан снимок текущего состояния как уже применённого." -ForegroundColor Yellow
  Write-Host "ВАЖНО: если сейчас в папке лежат ещё НЕ применённые правки," -ForegroundColor Yellow
  Write-Host "сначала выполните .\deploy.ps1, иначе они будут считаться применёнными." -ForegroundColor Yellow
  Write-Host "Путь эталона: $Baseline" -ForegroundColor Gray
  Write-Log "Инициализирован эталон"
  exit 0
}

# ------------------------------------------------------------------ сравнение

$current = @{}
foreach ($rel in Get-TrackedFiles $Here)   { $current[$rel] = Join-Path $Here $rel }
$base    = @{}
foreach ($rel in Get-TrackedFiles $Baseline) { $base[$rel]    = Join-Path $Baseline $rel }

$added = @($current.Keys | Where-Object { -not $base.ContainsKey($_) } | Sort-Object)
$deleted = @($base.Keys  | Where-Object { -not $current.ContainsKey($_) } | Sort-Object)

$modified = New-Object System.Collections.Generic.List[string]
foreach ($rel in $current.Keys) {
  if ($base.ContainsKey($rel)) {
    $h1 = (Get-FileHash -LiteralPath $current[$rel] -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $base[$rel]    -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { $modified.Add($rel) }
  }
}
$modified = @($modified | Sort-Object)

$total = $added.Count + $deleted.Count + $modified.Count

Write-Host ""
Write-Host "=== Проверка изменений относительно последнего применённого состояния ===" -ForegroundColor Cyan
Write-Host ""

if ($total -eq 0) {
  Write-Host "Изменений нет." -ForegroundColor Green
  Write-Host "Папка совпадает с эталоном; пересборка не требуется." -ForegroundColor Gray
  exit 0
}

if ($modified.Count) {
  Write-Host "Изменены ($($modified.Count)):" -ForegroundColor Yellow
  foreach ($f in $modified) { Write-Host "  M  $f" }
}
if ($added.Count) {
  Write-Host "Добавлены ($($added.Count)):" -ForegroundColor Yellow
  foreach ($f in $added) { Write-Host "  A  $f" }
}
if ($deleted.Count) {
  Write-Host "Удалены ($($deleted.Count)):" -ForegroundColor Yellow
  foreach ($f in $deleted) { Write-Host "  D  $f" }
}

# ------------------------------------------------------------------ показ diff

Write-Host ""
Write-Host "=== Diff ===" -ForegroundColor Cyan

foreach ($f in ($modified + $added + $deleted)) {
  Write-Host ""
  Write-Host ("########## {0} ##########" -f $f) -ForegroundColor White

  $curPath = $current[$f]
  $basPath = $base[$f]
  $display = $null

  if ($curPath -and $basPath) {
    if (-not (Test-IsText $curPath)) {
      $s1 = (Get-Item -LiteralPath $basPath).Length
      $s2 = (Get-Item -LiteralPath $curPath).Length
      $display = "Двоичный файл: размер $s1 -> $s2 байт"
    }
    else {
      $display = Get-UnifiedDiff (Get-FileText $basPath) (Get-FileText $curPath) "эталон/$f" "текущий/$f"
    }
  }
  elseif ($curPath) {
    if (-not (Test-IsText $curPath)) { $display = "Двоичный файл (добавлен), $((Get-Item -LiteralPath $curPath).Length) байт" }
    else { $display = Get-UnifiedDiff @() (Get-FileText $curPath) "/dev/null" "текущий/$f" }
  }
  else {
    if (-not (Test-IsText $basPath)) { $display = "Двоичный файл (удалён), был $((Get-Item -LiteralPath $basPath).Length) байт" }
    else { $display = Get-UnifiedDiff (Get-FileText $basPath) @() "эталон/$f" "/dev/null" }
  }

  Write-Host $display
}

# ------------------------------------------------------------------ подтверждение

if ($Check) {
  Write-Host ""
  Write-Host "Режим -Check: изменения показаны, ничего не применено." -ForegroundColor Yellow
  exit 0
}

Write-Host ""
Write-Host ("Итого: изменено {0}, добавлено {1}, удалено {2}." -f $modified.Count, $added.Count, $deleted.Count) -ForegroundColor Cyan

if (-not $Yes) {
  $ans = Read-Host "Применить изменения, пересобрать и перезапустить контейнер? [y/N]"
  if ($ans -notmatch '^(y|yes|д|да)$') {
    Write-Host "Отменено. Ничего не изменено." -ForegroundColor Yellow
    exit 0
  }
}

# ------------------------------------------------------------------ применение

try { docker version | Out-Null } catch { Fail "Docker Desktop не запущен." }

# Останавливаем контейнер, чтобы резервная копия SQLite (с WAL) была согласованной.
Write-Host "`nОстанавливаю контейнер..." -ForegroundColor Gray
docker compose stop | Out-Null

# Резервная копия БД.
New-Item -ItemType Directory -Force -Path ".\data\backups" | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
foreach ($sfx in @(".db", ".db-wal", ".db-shm")) {
  $dbFile = Join-Path $Here ("data\vacation.db" + $sfx)
  if (Test-Path -LiteralPath $dbFile) {
    Copy-Item -LiteralPath $dbFile -Destination (Join-Path $Here ("data\backups\pre-apply-$stamp" + $sfx)) -Force
  }
}
Write-Host "Резервная копия БД: data\backups\pre-apply-$stamp.db" -ForegroundColor Gray

Write-Host "Сборка и запуск..." -ForegroundColor Gray
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
  Write-Host "Ошибка сборки. Пробую вернуть предыдущий образ..." -ForegroundColor Red
  docker compose up -d | Out-Null
  docker compose logs --tail 100
  Fail "Изменения НЕ применены, эталон не обновлён."
}

# Проверка готовности.
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    if ((Invoke-WebRequest -UseBasicParsing "http://localhost:8086/healthz" -TimeoutSec 3).Content -eq "ok") { $ready = $true; break }
  } catch {}
  Start-Sleep -Seconds 2
}

if (-not $ready) {
  Write-Host "Сервис не прошёл проверку здоровья. Логи:" -ForegroundColor Red
  docker compose logs --tail 100
  Write-Host "Пробую вернуть предыдущий образ..." -ForegroundColor Red
  docker compose up -d | Out-Null
  Fail "Изменения НЕ применены, эталон не обновлён."
}

# Успех: фиксируем новое состояние как эталон.
Update-Baseline
$note = if ($Message) { $Message } else { "изменено $($modified.Count), добавлено $($added.Count), удалено $($deleted.Count)" }
Write-Log "Изменения применены. $note"
Write-Host ""
Write-Host "Готово: изменения применены, эталон обновлён." -ForegroundColor Green
Write-Host "http://localhost:8086" -ForegroundColor Green
