#Requires -Version 5.1
<#
.SYNOPSIS
    Восстанавливает базу PostgreSQL из дампа, созданного backup.ps1.

.DESCRIPTION
    Копирует дамп в контейнер db, проверяет его через pg_restore -l, очищает
    схему public и запускает pg_restore с --clean --if-exists.
    Параметры подключения берутся из .env (POSTGRES_DB, POSTGRES_USER).
    Успех определяется не кодом pg_restore (предупреждения --clean дают
    ненулевой код), а тем, что после очистки схемы в products появились
    строки из дампа: ноль строк или нечитаемая таблица — провал.

.PARAMETER File
    Путь к файлу дампа (.dump). Обязательный параметр.

.PARAMETER Force
    Не спрашивать подтверждение перед перезаписью базы.

.EXAMPLE
    .\scripts\restore.ps1 -File .\backups\20260101-120000.dump

.EXAMPLE
    .\scripts\restore.ps1 -File .\backups\20260101-120000.dump -Force
#>
[CmdletBinding()]
param(
    [string]$File,
    [switch]$Force
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

if ([string]::IsNullOrWhiteSpace($File)) {
    Fail 'Не указан файл дампа. Пример: .\scripts\restore.ps1 -File .\backups\20260101-120000.dump'
}

try {
    $source = (Resolve-Path -LiteralPath $File -ErrorAction Stop).Path
}
catch {
    Fail "Файл не найден: $File"
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
    Fail 'Контейнер db не запущен. Выполните: docker compose up -d'
}

if (-not $Force) {
    Write-Output "Восстановление перезапишет данные в базе '$db'."
    # При закрытом stdin Read-Host возвращает $null, а -notmatch на $null
    # не срабатывает (восстановление пошло бы без подтверждения). Поэтому
    # сначала гарантированно получаем строку, а пустой ответ считаем отказом.
    $raw = Read-Host 'Продолжить? [y/N]'
    $answer = ('' + $raw).Trim().ToLowerInvariant()
    if (@('y', 'yes', 'д', 'да') -notcontains $answer) {
        Write-Error 'Восстановление отменено.'
        exit 1
    }
}

Write-Output "Файл: $source"
Write-Output 'Копирую дамп в контейнер db...'

# docker compose cp пишет прогресс в stderr. PS 5.1 превращает его в
# объекты ошибок, поэтому строки приводим к тексту и печатаем сами.
$copyLog = @(docker compose cp $source db:/tmp/restore.dump 2>&1 | ForEach-Object { "$_" })
$copyCode = $LASTEXITCODE
$copyLog | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Output ($_ -replace '^docker :\s*', '').Trim() }
if ($copyCode -ne 0) {
    Fail "Не удалось скопировать дамп в контейнер (код $copyCode)."
}

# Дамп проверяется до любых изменений в базе: битый или чужой файл не должен
# даже доходить до очистки схемы.
Write-Output 'Проверяю дамп (pg_restore -l)...'

$listLog = @(docker compose exec -T db pg_restore -l /tmp/restore.dump 2>&1 | ForEach-Object { "$_" })
$listCode = $LASTEXITCODE

if ($listCode -ne 0) {
    docker compose exec -T db rm -f /tmp/restore.dump | Out-Null
    $detail = Get-LastLogLine -Lines $listLog
    if ($detail) {
        Fail "Дамп не читается: $detail"
    }
    Fail "Дамп не читается: pg_restore -l завершился с кодом $listCode."
}

# Явная очистка схемы: после неё таблицы products в базе заведомо нет, и
# найденные далее строки могут прийти только из дампа.
Write-Output 'Очищаю схему public...'

docker compose exec -T db psql -U $user -d $db -c 'drop schema public cascade; create schema public;'
if ($LASTEXITCODE -ne 0) {
    Fail "Не удалось очистить схему public (psql код $LASTEXITCODE)."
}

Write-Output 'Восстанавливаю базу...'

docker compose exec -T db pg_restore -U $user -d $db --clean --if-exists --no-owner /tmp/restore.dump
$restoreCode = $LASTEXITCODE
Write-Output "pg_restore код: $restoreCode"

# Код pg_restore сам по себе не приговор: --clean даёт предупреждения и
# ненулевой код. Приговор выносит проверка данных ниже, но код печатаем.
$countOutput = docker compose exec -T db psql -U $user -d $db -tAc 'select count(*) from products' 2>$null
$countCode = $LASTEXITCODE
$countText = ($countOutput | Out-String).Trim()

if ($countCode -ne 0 -or $countText -notmatch '^\d+$') {
    Fail "Восстановление не удалось: таблица products недоступна (psql код $countCode, pg_restore код $restoreCode)."
}

if ([int]$countText -le 0) {
    Fail "Восстановление не удалось: в таблице products 0 строк — данные из дампа не загрузились (pg_restore код $restoreCode)."
}

docker compose exec -T db rm -f /tmp/restore.dump | Out-Null

Write-Output "Восстановлено: таблица products, строк: $countText"
exit 0
