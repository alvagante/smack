# Smack for Windows

Plan: [windows-plan.md](../docs/development/windows-plan.md). Architecture and rules: [windows-architecture.md](../docs/development/windows-architecture.md).

```bash
cd windows
dotnet test            # Smack.Core is platform-neutral: runs on Windows, macOS and Linux
dotnet test -c Release
```

Needs the .NET 10 SDK (`winget install Microsoft.DotNet.SDK.10`, or `brew install dotnet` on macOS).

- Test first, as in the macOS target. Tests never touch the real system or the wall clock: inject collectors, and drive time with `ManualTimeProvider`.
- Collection is scheduled only by `CollectionEngine`. A new data source is a Source with a cost tier, a demand taken by the Page that shows it, and a test asserting when it runs.
- Warnings are errors. No runtime package without a recorded decision.
