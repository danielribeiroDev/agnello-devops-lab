using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;

internal static class DemoSecurity
{
    internal static void Configure(WebApplicationBuilder builder, string audience, string scope)
    {
        var certificate = X509CertificateLoader.LoadPkcs12FromFile(
            SecretPath($"{audience}_tls_certificate"),
            ReadSecret($"{audience}_tls_password"),
            X509KeyStorageFlags.EphemeralKeySet);

        builder.WebHost.ConfigureKestrel(options =>
        {
            options.ListenAnyIP(8080);
            options.ListenAnyIP(8443, endpoint => endpoint.UseHttps(certificate));
        });

        using var rsa = RSA.Create();
        rsa.ImportFromPem(ReadSecret("jwt_public_key"));
        var publicKey = new RsaSecurityKey(rsa.ExportParameters(includePrivateParameters: false));

        builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
        {
            options.MapInboundClaims = false;
            options.IncludeErrorDetails = false;
            options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidIssuer = "vinheria-agnello-demo",
                ValidateIssuer = true,
                ValidAudience = audience,
                ValidateAudience = true,
                IgnoreTrailingSlashWhenValidatingAudience = false,
                IssuerSigningKey = publicKey,
                ValidateIssuerSigningKey = true,
                ValidateLifetime = true,
                RequireExpirationTime = true,
                RequireSignedTokens = true,
                ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
                ClockSkew = TimeSpan.Zero
            };
        });

        builder.Services.AddAuthorization(options => options.DefaultPolicy = new AuthorizationPolicyBuilder()
            .RequireAuthenticatedUser()
            .RequireClaim("scope", scope)
            .Build());
    }

    internal static string SecretPath(string name) => Path.Combine("/run/secrets", name);

    internal static string ReadSecret(string name) => File.ReadAllText(SecretPath(name)).Trim();
}
