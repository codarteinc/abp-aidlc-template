using System;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;

namespace SmokeApp.Data;

public class SmokeAppDbMigrationService
{
    private readonly IConfiguration _configuration;

    public SmokeAppDbMigrationService(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    private async Task SeedDataAsync()
    {
        await Task.CompletedTask;
    }
}
