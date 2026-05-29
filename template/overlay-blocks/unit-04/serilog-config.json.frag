  "Serilog": {
    "MinimumLevel": {
      "Default": "Information",
      "Override": {
        "Microsoft": "Information",
        "Microsoft.EntityFrameworkCore": "Warning"
      }
    },
    "Enrich": ["FromLogContext"],
    "WriteTo": [
      {
        "Name": "Async",
        "Args": {
          "configure": [
            {
              "Name": "File",
              "Args": {
                "path": "Logs/log-.txt",
                "rollingInterval": "Day",
                "retainedFileCountLimit": 14,
                "fileSizeLimitBytes": 10485760,
                "rollOnFileSizeLimit": true,
                "shared": false,
                "outputTemplate": "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{CorrelationId}] [trace={TraceId} span={SpanId}] {Message:lj} {Exception}{NewLine}"
              }
            }
          ]
        }
      },
      {
        "Name": "Async",
        "Args": {
          "configure": [
            { "Name": "Console" }
          ]
        }
      }
    ]
  },
