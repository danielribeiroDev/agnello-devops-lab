using Microsoft.EntityFrameworkCore;

internal sealed class OrdersDbContext(DbContextOptions<OrdersDbContext> options) : DbContext(options)
{
    public DbSet<Order> Orders => Set<Order>();
}

internal sealed record Order(Guid Id, string Sku, int Quantity);
