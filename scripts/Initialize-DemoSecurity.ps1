#Requires -Version 7.4

using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

$ErrorActionPreference = 'Stop'
$secretDirectory = Join-Path (Split-Path $PSScriptRoot) '.demo-security'
$now = [DateTimeOffset]::UtcNow

function ConvertTo-Base64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-DemoToken {
    param (
        [RSA]$Key,
        [string]$Subject,
        [string]$Audience,
        [string]$Scope,
        [DateTimeOffset]$IssuedAt,
        [DateTimeOffset]$ExpiresAt
    )

    # shortcut: issue local test fixtures offline; use an OAuth authorization server outside the demo.
    $header = '{"alg":"RS256","typ":"JWT"}'
    $payload = @{
        iss = 'vinheria-agnello-demo'
        aud = $Audience
        sub = $Subject
        client_id = $Subject
        scope = $Scope
        iat = $IssuedAt.ToUnixTimeSeconds()
        nbf = $IssuedAt.ToUnixTimeSeconds()
        exp = $ExpiresAt.ToUnixTimeSeconds()
        jti = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    $encodedHeader = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))
    $encodedPayload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload))
    $signedContent = "$encodedHeader.$encodedPayload"
    $signature = $Key.SignData([Text.Encoding]::ASCII.GetBytes($signedContent), [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1)
    "$signedContent.$(ConvertTo-Base64Url $signature)"
}

function New-ServiceCertificate {
    param ([string]$Name, [RSA]$Key, [X509Certificate2]$Issuer)

    $request = [CertificateRequest]::new("CN=$Name", $Key, [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add([X509BasicConstraintsExtension]::new($false, $false, 0, $true))
    $request.CertificateExtensions.Add([X509KeyUsageExtension]::new([X509KeyUsageFlags]::DigitalSignature, $true))
    $serverUsage = [OidCollection]::new()
    [void]$serverUsage.Add([Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add([X509EnhancedKeyUsageExtension]::new($serverUsage, $false))

    $names = [SubjectAlternativeNameBuilder]::new()
    $names.AddDnsName('localhost')
    $names.AddDnsName($Name)
    $request.CertificateExtensions.Add($names.Build())

    $serialNumber = [RandomNumberGenerator]::GetBytes(16)
    $publicCertificate = $request.Create($Issuer, $now.AddMinutes(-5), $now.AddDays(7), $serialNumber)
    try { [RSACertificateExtensions]::CopyWithPrivateKey($publicCertificate, $Key) }
    finally { $publicCertificate.Dispose() }
}

$caKey = [RSA]::Create(2048)
$jwtKey = [RSA]::Create(2048)
$ca = $null
try {
    $caRequest = [CertificateRequest]::new('CN=Vinheria Agnello Demo CA', $caKey, [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1)
    $caRequest.CertificateExtensions.Add([X509BasicConstraintsExtension]::new($true, $true, 0, $true))
    $caRequest.CertificateExtensions.Add([X509KeyUsageExtension]::new([X509KeyUsageFlags]::KeyCertSign, $true))
    $ca = $caRequest.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(8))

    $expires = $now.AddHours(1)
    $files = @{
        'ca.pem' = $ca.ExportCertificatePem()
        'jwt-public.pem' = $jwtKey.ExportSubjectPublicKeyInfoPem()
        'orders.jwt' = New-DemoToken $jwtKey 'demo-client' 'orders' 'orders:access' $now $expires
        'inventory.jwt' = New-DemoToken $jwtKey 'orders-service' 'inventory' 'inventory:read' $now $expires
        'expired-orders.jwt' = New-DemoToken $jwtKey 'demo-client' 'orders' 'orders:access' ($now.AddHours(-2)) ($now.AddHours(-1))
        'forbidden-orders.jwt' = New-DemoToken $jwtKey 'demo-client' 'orders' 'inventory:read' $now $expires
    }

    foreach ($service in @('orders', 'inventory')) {
        $serviceKey = [RSA]::Create(2048)
        $certificate = $null
        try {
            $certificate = New-ServiceCertificate $service $serviceKey $ca
            $password = ConvertTo-Base64Url ([RandomNumberGenerator]::GetBytes(32))
            $files["$service-password.txt"] = $password
            $files["$service.pfx"] = $certificate.Export([X509ContentType]::Pfx, $password)
        }
        finally {
            if ($certificate) { $certificate.Dispose() }
            $serviceKey.Dispose()
        }
    }

    [void][IO.Directory]::CreateDirectory($secretDirectory)
    foreach ($file in $files.GetEnumerator()) {
        $path = Join-Path $secretDirectory $file.Key
        if ($file.Value -is [byte[]]) { [IO.File]::WriteAllBytes($path, $file.Value) }
        else { [IO.File]::WriteAllText($path, $file.Value) }
    }

    Write-Host "Demo security files generated. Tokens expire at $($expires.UtcDateTime.ToString('u'))."
}
finally {
    if ($ca) { $ca.Dispose() }
    $caKey.Dispose()
    $jwtKey.Dispose()
}
