#Requires -Version 5.1
<#
.SYNOPSIS
    Создаёт резервную копию базы PostgreSQL из контейнера db.

.DESCRIPTION
    Параметры подключения берутся из .env (POSTGRES_DB, POSTGRES_USER).
    Дамп снимается внутри контейнера через pg_dump в формате custom,
    проверяется там же через pg_restore -l и только потом копируется
    на хост в каталог OutDir.

.PARAMETER OutDir
    Каталог для дампов. По умолчанию .\backups.

.EXAMPLE
    .\scripts\backup.ps1

.EXAMPLE
    .\scripts\backup.ps1 -OutDir D:\dumps
#>
[CmdletBinding()]
param(
    [string]$OutDir = '.\backups'
)

# В PowerShell 5.1 при ErrorActionPreference = 'Stop' любая запись docker
# в stderr (а docker compose cp пишет прогресс именно туда) становится
# исключением. Поэтому оставляем Continue, а важные cmdlet вызываем
# с -ErrorAction Stop и ловим их в try/catch.
$ErrorActionPreference = 'Continue'

function Fail {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

function Read-EnvFile {
    param([string]$Path)

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

    if (-not $lines) {
        throw 'Файл .env не содержит ни одной пары ключ=значение.'
    }

    ConvertFrom-StringData -StringData ($lines -join "`n")
}

function Get-LastLogLine {
    param($Lines)

    $detail = @($Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($detail.Count -eq 0) {
        return $null
    }

    return $detail[-1]
}

$root = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $root '.env'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'Docker не найден в PATH. Установите и запустите Docker Desktop.'
}

if (-not (Test-Path -LiteralPath $envPath)) {
    Fail 'Нет .env: скопируйте .env.example в .env.'
}

try {
    $envValues = Read-EnvFile -Path $envPath
}
catch {
    Fail "Не удалось прочитать .env: $($_.Exception.Message)"
}

$db = $envValues['POSTGRES_DB']
$user = $envValues['POSTGRES_USER']

if ([string]::IsNullOrWhiteSpace($db)) {
    Fail 'В .env не задан POSTGRES_DB.'
}

if ([string]::IsNullOrWhiteSpace($user)) {
    Fail 'В .env не задан POSTGRES_USER.'
}

# Дальше все относительные пути считаются от корня проекта,
# поэтому скрипт можно запускать из любого каталога.
Push-Location -LiteralPath $root

$dbContainer = docker compose ps -q db
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($dbContainer | Out-String))) {
    Fail 'Контейнер db не запущен — сначала docker compose up -d'
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    try {
        New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Fail "Не удалось создать каталог для бэкапов: $($_.Exception.Message)"
    }
}

try {
    $outFull = (Resolve-Path -LiteralPath $OutDir -ErrorAction Stop).Path
}
catch {
    Fail "Не удалось определить путь к каталогу бэкапов: $($_.Exception.Message)"
}

$fileName = '{0}.dump' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$target = Join-Path $outFull $fileName

Write-Output "База: $db, пользователь: $user"
Write-Output 'Создаю дамп внутри контейнера db...'

docker compose exec -T db pg_dump -U $user -d $db -Fc -f /tmp/backup.dump
if ($LASTEXITCODE -ne 0) {
    Fail "pg_dump завершился с кодом $LASTEXITCODE."
}

# Битый дамп должен падать здесь, а не при восстановлении.
Write-Output 'Проверяю дамп (pg_restore -l)...'

$listLog = @(docker compose exec -T db pg_restore -l /tmp/backup.dump 2>&1 | ForEach-Object { "$_" })
$listCode = $LASTEXITCODE

if ($listCode -ne 0) {
    docker compose exec -T db rm -f /tmp/backup.dump | Out-Null
    $detail = Get-LastLogLine -Lines $listLog
    if ($detail) {
        Fail "Дамп не читается: $detail"
    }
    Fail "Дамп не читается: pg_restore -l завершился с кодом $listCode."
}

# docker compose cp пишет прогресс в stderr. PS 5.1 превращает его в
# объекты ошибок, поэтому строки приводим к тексту и печатаем сами.
$copyLog = @(docker compose cp db:/tmp/backup.dump $target 2>&1 | ForEach-Object { "$_" })
$copyCode = $LASTEXITCODE
$copyLog | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Output ($_ -replace '^docker :\s*', '').Trim() }
if ($copyCode -ne 0) {
    Fail "Не удалось скопировать дамп из контейнера (код $copyCode)."
}

docker compose exec -T db rm -f /tmp/backup.dump | Out-Null

if (-not (Test-Path -LiteralPath $target)) {
    Fail "Дамп не появился на диске: $target"
}

$size = (Get-Item -LiteralPath $target -ErrorAction Stop).Length

if ($size -le 0) {
    Fail "Файл дампа пуст: $target"
}

Write-Output "Бэкап: $target ($size байт)"
exit 0
