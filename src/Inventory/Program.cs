using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddProblemDetails();
DemoSecurity.Configure(builder, "inventory", "inventory:read");
builder.Services.AddDbContext<InventoryDbContext>(options => options.UseSqlite(
    builder.Configuration.GetConnectionString("Inventory") ?? "Data Source=inventory.db"));

var app = builder.Build();
app.UseExceptionHandler();

await using (var scope = app.Services.CreateAsyncScope())
{
    var database = scope.ServiceProvider.GetRequiredService<InventoryDbContext>();
    await database.Database.EnsureCreatedAsync();
}

app.MapGet("/stock/{sku}", async (string sku, InventoryDbContext database, CancellationToken cancellationToken) =>
{
    var stock = await database.StockItems.FindAsync([sku], cancellationToken);
    return stock is null ? Results.NotFound() : Results.Ok(stock);
}).RequireAuthorization();

await app.RunAsync();
