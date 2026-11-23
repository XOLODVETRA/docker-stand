#Requires -Version 5.1
<#
.SYNOPSIS
    Проверяет, что стенд поднят и данные в базе на месте.

.DESCRIPTION
    Четыре проверки: все контейнеры запущены, сайт отвечает по HTTP,
    Adminer отвечает по HTTP, в таблице products ожидаемое число строк.
    Параметры подключения берутся из .env. Код возврата 0 — все проверки
    прошли, иначе 1.

.PARAMETER ExpectedProducts
    Ожидаемое число строк в таблице products. По умолчанию 24.

.EXAMPLE
    .\scripts\check.ps1

.EXAMPLE
    .\scripts\check.ps1 -ExpectedProducts 30
#>
[CmdletBinding()]
param(
    [int]$ExpectedProducts = 24
)

# Ошибки отдельных проверок обрабатываются в try/catch, а не обрывают скрипт.
$ErrorActionPreference = 'Continue'

$script:passed = 0
$total = 4

function Fail {
    param([string]$Message)
    # Write-Error добавляет к строке At line, CategoryInfo и
    # FullyQualifiedErrorId; для пользователя нужна одна чистая строка.
    $host.UI.WriteErrorLine("Fail : $Message")
    exit 1
}

function Report-Check {
    param(
        [bool]$Ok,
        [string]$Text
    )

    if ($Ok) {
        $script:passed++
        Write-Output "[OK] $Text"
    }
    else {
        Write-Output "[FAIL] $Text"
    }
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

function Get-HttpStatusCode {
    param([string]$Url)

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
    return [int]$response.StatusCode
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
$port = $envValues['STACK_PORT']

if ([string]::IsNullOrWhiteSpace($db)) {
    Fail 'В .env не задан POSTGRES_DB.'
}

if ([string]::IsNullOrWhiteSpace($user)) {
    Fail 'В .env не задан POSTGRES_USER.'
}

if ([string]::IsNullOrWhiteSpace($port)) {
    Fail 'В .env не задан STACK_PORT.'
}

$siteUrl = "http://127.0.0.1:$port/"
$adminerUrl = "http://127.0.0.1:$port/adminer/"

# Дальше все относительные пути считаются от корня проекта,
# поэтому скрипт можно запускать из любого каталога.
Push-Location -LiteralPath $root

# 1. Контейнеры.
try {
    $runningRaw = docker compose ps --status running --format '{{.Service}}'
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose ps вернул код $LASTEXITCODE"
    }

    $running = @($runningRaw | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\S' })
    $required = @('db', 'adminer', 'nginx')
    $missing = @($required | Where-Object { $running -notcontains $_ })

    if ($missing.Count -gt 0) {
        Report-Check $false ("Контейнеры: запущено [{0}], не хватает: {1}" -f ($running -join ', '), ($missing -join ', '))
    }
    else {
        Report-Check $true ("Все контейнеры запущены: {0}" -f ($running -join ', '))
    }
}
catch {
    Report-Check $false "Не удалось получить список контейнеров: $($_.Exception.Message)"
}

# 2. Сайт.
try {
    $code = Get-HttpStatusCode -Url $siteUrl
    Report-Check ($code -eq 200) "Сайт $siteUrl — код $code"
}
catch {
    Report-Check $false "Сайт $siteUrl недоступен: $($_.Exception.Message)"
}

# 3. Adminer.
try {
    $code = Get-HttpStatusCode -Url $adminerUrl
    Report-Check ($code -eq 200) "Adminer $adminerUrl — код $code"
}
catch {
    Report-Check $false "Adminer $adminerUrl недоступен: $($_.Exception.Message)"
}

# 4. Данные.
try {
    $countOutput = docker compose exec -T db psql -U $user -d $db -tAc 'select count(*) from products' 2>$null
    $countCode = $LASTEXITCODE
    $countText = ($countOutput | Out-String).Trim()

    if ($countCode -ne 0) {
        throw "psql вернул код $countCode — таблица products недоступна"
    }

    if ($countText -notmatch '^\d+$') {
        throw "psql вернул не число: '$countText'"
    }

    $actual = [int]$countText
    Report-Check ($actual -eq $ExpectedProducts) "Таблица products: строк $actual, ожидалось $ExpectedProducts"
}
catch {
    Report-Check $false "Данные в базе: $($_.Exception.Message)"
}

Write-Output "Итог: $script:passed из $total проверок пройдено"

if ($script:passed -lt $total) {
    exit 1
}

exit 0
