using Microsoft.EntityFrameworkCore;

internal sealed class InventoryDbContext(DbContextOptions<InventoryDbContext> options) : DbContext(options)
{
    public DbSet<StockItem> StockItems => Set<StockItem>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var stockItem = modelBuilder.Entity<StockItem>();
        stockItem.HasKey(item => item.Sku);
        stockItem.HasData(new StockItem("WINE-001", 10));
    }
}

internal sealed record StockItem(string Sku, int AvailableQuantity);
