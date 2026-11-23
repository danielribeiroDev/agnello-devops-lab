using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddProblemDetails();
DemoSecurity.Configure(builder, "orders", "orders:access");
builder.Services.AddDbContext<OrdersDbContext>(options => options.UseSqlite(
    builder.Configuration.GetConnectionString("Orders") ?? "Data Source=orders.db"));

if (!Uri.TryCreate(builder.Configuration["Inventory:BaseUrl"], UriKind.Absolute, out var inventoryHttpsUrl) ||
    inventoryHttpsUrl.Scheme != Uri.UriSchemeHttps)
{
    throw new InvalidOperationException("Inventory:BaseUrl must be an absolute HTTPS URL.");
}

if (!Uri.TryCreate(builder.Configuration["Inventory:HttpBaseUrl"], UriKind.Absolute, out var inventoryHttpUrl) ||
    inventoryHttpUrl.Scheme != Uri.UriSchemeHttp)
{
    throw new InvalidOperationException("Inventory:HttpBaseUrl must be an absolute HTTP URL.");
}

using var inventoryCa = X509CertificateLoader.LoadCertificateFromFile(DemoSecurity.SecretPath("demo_ca"));
var inventoryToken = DemoSecurity.ReadSecret("inventory_service_token");
builder.Services.AddHttpClient("Inventory", client =>
{
    client.Timeout = TimeSpan.FromSeconds(5);
    client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", inventoryToken);
}).ConfigurePrimaryHttpMessageHandler(() =>
{
    // shortcut: the local demo CA publishes no revocation list; use a revocation-enabled policy for a managed CA.
    var trust = new X509ChainPolicy
    {
        TrustMode = X509ChainTrustMode.CustomRootTrust,
        RevocationMode = X509RevocationMode.NoCheck,
        DisableCertificateDownloads = true
    };
    trust.CustomTrustStore.Add(inventoryCa);

    return new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseProxy = false,
        SslOptions = new SslClientAuthenticationOptions { CertificateChainPolicy = trust }
    };
});

var app = builder.Build();
app.UseExceptionHandler();

await using (var scope = app.Services.CreateAsyncScope())
{
    var database = scope.ServiceProvider.GetRequiredService<OrdersDbContext>();
    await database.Database.EnsureCreatedAsync();
}

var orders = app.MapGroup("/orders").RequireAuthorization();
orders.MapGet("/{id:guid}", async (Guid id, OrdersDbContext database, CancellationToken cancellationToken) =>
{
    var order = await database.Orders.FindAsync([id], cancellationToken);
    return order is null ? Results.NotFound() : Results.Ok(order);
});

orders.MapPost("", CreateOrderAsync);

await app.RunAsync();

async Task<IResult> CreateOrderAsync(
    CreateOrderRequest request,
    HttpRequest incomingRequest,
    IHttpClientFactory httpClientFactory,
    OrdersDbContext database,
    CancellationToken cancellationToken)
{
    var sku = request.Sku?.Trim();
    if (string.IsNullOrEmpty(sku) || request.Quantity <= 0)
    {
        return Results.Problem(statusCode: 400, title: "A SKU and a positive quantity are required.");
    }

    StockAvailability? stock;
    try
    {
        // shortcut: preserve plaintext for the lab comparison; require HTTPS on both hops outside the lab.
        var inventoryUrl = incomingRequest.IsHttps ? inventoryHttpsUrl : inventoryHttpUrl;
        var stockUrl = new Uri(inventoryUrl, $"/stock/{Uri.EscapeDataString(sku)}");
        using var client = httpClientFactory.CreateClient("Inventory");
        using var response = await client.GetAsync(stockUrl, cancellationToken);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return Results.Problem(statusCode: 404, title: "SKU not found.");
        }

        response.EnsureSuccessStatusCode();
        stock = await response.Content.ReadFromJsonAsync<StockAvailability>(cancellationToken);
    }
    catch (Exception error) when (error is HttpRequestException or JsonException or NotSupportedException ||
                                  error is OperationCanceledException && !cancellationToken.IsCancellationRequested)
    {
        return InventoryUnavailable();
    }

    if (stock is null || stock.Sku != sku || stock.AvailableQuantity is not int availableQuantity || availableQuantity < 0)
    {
        return InventoryUnavailable();
    }

    if (request.Quantity > availableQuantity)
    {
        return Results.Problem(statusCode: 409, title: "Insufficient stock.");
    }

    var order = new Order(Guid.NewGuid(), sku, request.Quantity);
    database.Orders.Add(order);
    await database.SaveChangesAsync(cancellationToken);

    return Results.Created($"/orders/{order.Id}", order);
}

static IResult InventoryUnavailable() =>
    Results.Problem(statusCode: 503, title: "Inventory is unavailable.");

internal sealed record CreateOrderRequest(string? Sku, int Quantity);

internal sealed record StockAvailability(string Sku, int? AvailableQuantity);
