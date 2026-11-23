#Requires -Version 5.1
<#
.SYNOPSIS
    Восстанавливает базу PostgreSQL из дампа, созданного backup.ps1.

.DESCRIPTION
    Копирует дамп в контейнер db, проверяет его через pg_restore -l, очищает
    схему public и запускает pg_restore с --exit-on-error --no-owner.
    Параметры подключения берутся из .env (POSTGRES_DB, POSTGRES_USER).
    Успех доказывается данными, а не только кодом возврата: ненулевой код
    pg_restore — провал; после восстановления в products должно быть больше
    нуля строк, а в categories ровно 3. Если проверка не прошла, скрипт
    называет её и код pg_restore и возвращает 1.

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
    # Write-Error добавляет к строке At line, CategoryInfo и
    # FullyQualifiedErrorId; для пользователя нужна одна чистая строка.
    $host.UI.WriteErrorLine("Fail : $Message")
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
        $host.UI.WriteErrorLine('Восстановление отменено.')
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

# --clean здесь не нужен: схема public уже снесена выше, а предупреждения
# --clean про отсутствующие объекты и давали тот ненулевой код, которому
# нельзя было верить. --exit-on-error останавливает восстановление на
# первой ошибке, поэтому её видно сразу.
docker compose exec -T db pg_restore -U $user -d $db --exit-on-error --no-owner /tmp/restore.dump
$restoreCode = $LASTEXITCODE
Write-Output "pg_restore код: $restoreCode"

if ($restoreCode -ne 0) {
    docker compose exec -T db rm -f /tmp/restore.dump | Out-Null
    Fail "Восстановление не удалось: pg_restore код $restoreCode."
}

# Два факта вместо одного: products непустая и categories ровно 3.
$countsOutput = docker compose exec -T db psql -U $user -d $db -tAc 'select (select count(*) from products), (select count(*) from categories)' 2>$null
$countsCode = $LASTEXITCODE
$countsText = ($countsOutput | Out-String).Trim()

if ($countsCode -ne 0 -or $countsText -notmatch '^(\d+)\|(\d+)$') {
    Fail "Восстановление не удалось: проверка products и categories не прошла — таблицы недоступны (psql код $countsCode, pg_restore код $restoreCode)."
}

$productRows = [int]$Matches[1]
$categoryRows = [int]$Matches[2]

if ($productRows -le 0) {
    Fail "Восстановление не удалось: проверка products не прошла — строк 0, ожидалось больше 0 (pg_restore код $restoreCode)."
}

if ($categoryRows -ne 3) {
    Fail "Восстановление не удалось: проверка categories не прошла — строк $categoryRows, ожидалось 3 (pg_restore код $restoreCode)."
}

docker compose exec -T db rm -f /tmp/restore.dump | Out-Null

Write-Output "Восстановлено: products — $productRows, categories — $categoryRows"
exit 0
