#Requires -Version 7.4

using namespace System.Net.Http
using namespace System.Net.Http.Headers
using namespace System.Security.Cryptography.X509Certificates

param ([guid]$ExistingOrderId = [guid]::Empty)

$ErrorActionPreference = 'Stop'
$secretDirectory = Join-Path (Split-Path $PSScriptRoot) '.demo-security'
$ordersUrl = 'https://localhost:8443/orders'
$stockUrl = 'https://localhost:8444/stock/WINE-001'
$httpOrdersUrl = 'http://localhost:8080/orders'
$httpStockUrl = 'http://localhost:8081/stock/WINE-001'
$unknownOrderUrl = "$ordersUrl/$([guid]::Empty)"

function Read-Token([string]$Name) {
    [IO.File]::ReadAllText((Join-Path $secretDirectory "$Name.jwt")).Trim()
}

function New-DemoClient([X509Certificate2]$Root) {
    $handler = [SocketsHttpHandler]::new()
    $handler.UseProxy = $false
    $handler.AllowAutoRedirect = $false
    if ($Root) {
        $policy = [X509ChainPolicy]::new()
        $policy.TrustMode = [X509ChainTrustMode]::CustomRootTrust
        $policy.RevocationMode = [X509RevocationMode]::NoCheck
        $policy.DisableCertificateDownloads = $true
        [void]$policy.CustomTrustStore.Add($Root)
        $handler.SslOptions.CertificateChainPolicy = $policy
    }
    $client = [HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $client
}

function Test-DemoRequest {
    param (
        [HttpClient]$Client,
        [string]$Scenario,
        [string]$Method,
        [string]$Uri,
        [int]$ExpectedStatus,
        [string]$Token,
        [hashtable]$Payload
    )

    $request = [HttpRequestMessage]::new([HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
    $response = $null
    try {
        if ($Token) { $request.Headers.Authorization = [AuthenticationHeaderValue]::new('Bearer', $Token) }
        if ($Payload) {
            $json = $Payload | ConvertTo-Json -Compress
            $request.Content = [StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }

        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -ne $ExpectedStatus) { throw "$Scenario returned $status. Expected $ExpectedStatus." }
        Write-Host "$Scenario => $status"
        if ($response.IsSuccessStatusCode) {
            @{
                Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                Location = [string]$response.Headers.Location
            }
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Test-RejectedConnection {
    param ([HttpClient]$Client, [string]$Scenario, [string]$Uri, [HttpRequestError]$ExpectedError)

    try {
        $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
        $response.Dispose()
    }
    catch {
        $cause = $_.Exception
        while ($cause -and $cause -isnot [HttpRequestException]) { $cause = $cause.InnerException }
        if ($null -eq $cause -or $cause.HttpRequestError -ne $ExpectedError) { throw }
        Write-Host "$Scenario => connection rejected"
        return
    }

    throw "$Scenario unexpectedly reached an HTTP endpoint."
}

$ordersToken = Read-Token 'orders'
$inventoryToken = Read-Token 'inventory'
$expiredToken = Read-Token 'expired-orders'
$forbiddenToken = Read-Token 'forbidden-orders'
$parts = $ordersToken.Split('.')
$replacement = if ($parts[2][0] -eq 'A') { 'B' } else { 'A' }
$parts[2] = $replacement + $parts[2].Substring(1)
$tamperedToken = $parts -join '.'

$ca = [X509Certificate2]::new((Join-Path $secretDirectory 'ca.pem'))
$client = New-DemoClient $ca
$untrustedClient = New-DemoClient
try {
    Test-RejectedConnection $untrustedClient 'TLS with an untrusted CA' $unknownOrderUrl SecureConnectionError
    Test-RejectedConnection $client 'TLS with a hostname mismatch' "https://127.0.0.1:8443/orders/$([guid]::Empty)" SecureConnectionError

    $payload = @{ sku = 'WINE-001'; quantity = 2 }
    $null = Test-DemoRequest $client 'GET /orders/{id} without a token' Get $unknownOrderUrl 401
    $null = Test-DemoRequest $client 'Orders with a tampered signature' Get $unknownOrderUrl 401 $tamperedToken
    $null = Test-DemoRequest $client 'Orders with an expired token' Get $unknownOrderUrl 401 $expiredToken
    $null = Test-DemoRequest $client 'Orders with the Inventory token' Get $unknownOrderUrl 401 $inventoryToken
    $null = Test-DemoRequest $client 'Inventory with the Orders token' Get $stockUrl 401 $ordersToken
    $null = Test-DemoRequest $client 'Orders with a valid token and wrong scope' Get $unknownOrderUrl 403 $forbiddenToken

    if ($ExistingOrderId -ne [guid]::Empty) {
        $persisted = Test-DemoRequest $client 'Read a persisted order' Get "$ordersUrl/$ExistingOrderId" 200 $ordersToken
        if ($persisted.Body.id -ne $ExistingOrderId.ToString()) { throw 'The returned order ID differs from the persisted ID.' }
        Write-Host "Persisted order: $ExistingOrderId"
    }

    $flows = @(
        @{ Protocol = 'HTTP'; OrdersUrl = $httpOrdersUrl; StockUrl = $httpStockUrl }
        @{ Protocol = 'HTTPS'; OrdersUrl = $ordersUrl; StockUrl = $stockUrl }
    )
    foreach ($flow in $flows) {
        $protocol = $flow.Protocol
        $null = Test-DemoRequest $client "POST /orders over $protocol without a token" Post $flow.OrdersUrl 401 -Payload $payload
        $null = Test-DemoRequest $client "GET /stock/{sku} over $protocol without a token" Get $flow.StockUrl 401

        $stockBefore = Test-DemoRequest $client "Read stock over $protocol" Get $flow.StockUrl 200 $inventoryToken
        if ($stockBefore.Body.availableQuantity -ne 10) { throw 'Expected 10 units in stock.' }

        $created = Test-DemoRequest $client "Create an order over $protocol" Post $flow.OrdersUrl 201 $ordersToken $payload
        if ($created.Location -ne "/orders/$($created.Body.id)") { throw 'Unexpected Location header.' }
        $orderUrl = [uri]::new([uri]$flow.OrdersUrl, $created.Location).AbsoluteUri
        $savedOrder = Test-DemoRequest $client "Follow Location over $protocol" Get $orderUrl 200 $ordersToken
        if ($savedOrder.Body.id -ne $created.Body.id -or $savedOrder.Body.sku -ne 'WINE-001' -or $savedOrder.Body.quantity -ne 2) {
            throw 'Saved order does not match the submitted order.'
        }
        Write-Host "Created order ($protocol): $($savedOrder.Body.id)"

        $stockAfter = Test-DemoRequest $client "Read stock over $protocol after order creation" Get $flow.StockUrl 200 $inventoryToken
        if ($stockAfter.Body.availableQuantity -ne $stockBefore.Body.availableQuantity) { throw 'Stock quantity changed.' }
        Write-Host "Available quantity ($protocol): $($stockAfter.Body.availableQuantity)"
    }

    $null = Test-DemoRequest $client 'Unknown order' Get $unknownOrderUrl 404 $ordersToken
    $null = Test-DemoRequest $client 'Invalid quantity' Post $ordersUrl 400 $ordersToken @{ sku = 'WINE-001'; quantity = 0 }
    $null = Test-DemoRequest $client 'Blank SKU' Post $ordersUrl 400 $ordersToken @{ sku = ' '; quantity = 1 }
    $null = Test-DemoRequest $client 'Unknown SKU' Post $ordersUrl 404 $ordersToken @{ sku = 'UNKNOWN'; quantity = 1 }
    $null = Test-DemoRequest $client 'Insufficient stock' Post $ordersUrl 409 $ordersToken @{ sku = 'WINE-001'; quantity = 11 }

    Write-Host 'Demo checks passed.'
}
finally {
    $client.Dispose()
    $untrustedClient.Dispose()
    $ca.Dispose()
}
