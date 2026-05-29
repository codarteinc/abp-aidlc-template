using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;

public class Program
{
    public static async Task<int> Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);
        var app = builder.Build();
        await app.RunAsync();
        return 0;
    }
}
