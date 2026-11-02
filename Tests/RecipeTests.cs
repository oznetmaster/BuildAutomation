// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using BuildAutomation;
using NUnit.Framework;
using System.Text.Json;

public sealed class RecipeTests
{
    private string root = null!;
    [SetUp] public void Setup() => Directory.CreateDirectory(root = Path.Combine(Path.GetTempPath(), "build tests " + Guid.NewGuid()));
    [TearDown] public void Cleanup() => Directory.Delete(root, true);

    private string Trx(long total, long executed, long passed, long failed, string outcome = "Completed")
    {
        string file = Path.Combine(root, "tests.trx");
        File.WriteAllText(file, $"<TestRun xmlns='http://microsoft.com/schemas/VisualStudio/TeamTest/2010'><ResultSummary outcome='{outcome}'><Counters total='{total}' executed='{executed}' passed='{passed}' failed='{failed}' /></ResultSummary></TestRun>");
        return file;
    }

    [TestCase(0, 0, 0, 0, "Completed")]
    [TestCase(2, 2, 1, 1, "Failed")]
    [TestCase(2, 2, 1, 0, "Completed")]
    [TestCase(1, 2, 2, 0, "Completed")]
    [TestCase(2, 2, 2, 0, "Aborted")]
    public void RejectsUnsuccessfulTrx(int total, int executed, int passed, int failed, string outcome) =>
        Assert.Throws<InvalidDataException>(() => RecipeRunner.ReadTrx(Trx(total, executed, passed, failed, outcome)));

    [Test] public void ReportsSkippedTestsWithoutClaimingTheyExecuted()
    {
        var result = RecipeRunner.ReadTrx(Trx(5, 4, 4, 0));
        Assert.That(result.Passed, Is.EqualTo(4));
        Assert.That(result.Skipped, Is.EqualTo(1));
    }

    [TestCase("../outside.json")]
    [TestCase("folder/../../outside.json")]
    public void RejectsEscapingPaths(string path) => Assert.Throws<ArgumentException>(() => RecipeRunner.Inside(root, path));

    [Test] public void MissingInputFailsClosed() => Assert.Throws<ArgumentException>(() => RecipeRunner.Expand("${env:BUILD_TEST_MISSING_INPUT_5C8F}"));

    [Test] public void InputIsExpandedLiterally()
    {
        Environment.SetEnvironmentVariable("BUILD_TEST_INPUT_5C8F", "a path/with spaces;$(literal)");
        try { Assert.That(RecipeRunner.Expand("--project=${env:BUILD_TEST_INPUT_5C8F}"), Is.EqualTo("--project=a path/with spaces;$(literal)")); }
        finally { Environment.SetEnvironmentVariable("BUILD_TEST_INPUT_5C8F", null); }
    }

    private void Recipe(object task) => File.WriteAllText(Path.Combine(root, "recipe.json"), JsonSerializer.Serialize(new { schema = 1, tasks = new Dictionary<string, object> { ["test"] = task } }));

    [Test] public void UnknownTaskDoesNotExecute() => Assert.Throws<ArgumentException>(() =>
    { Recipe(new { commands = new[] { new { executable = "dotnet", arguments = new[] { "--version" } } } }); RecipeRunner.Run(root, "recipe.json", "other"); });

    [Test] public void RejectsStaleTestResults()
    {
        Directory.CreateDirectory(Path.Combine(root, "results"));
        File.Move(Trx(2, 2, 2, 0), Path.Combine(root, "results", "stale.trx"));
        Recipe(new { commands = new[] { new { executable = "dotnet", arguments = new[] { "--version" } } }, results = new[] { "results/*.trx" } });
        Assert.Throws<InvalidDataException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
    }

    [Test] public void RejectsMissingTestResults()
    {
        Recipe(new { commands = new[] { new { executable = "dotnet", arguments = new[] { "--version" } } }, results = new[] { "results/**/*.trx" } });
        Assert.Throws<InvalidDataException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
    }

    [Test] public void FailedCommandStopsBeforeLaterCommands()
    {
        File.WriteAllText(Path.Combine(root, "should-not-run.ps1"), "Set-Content -LiteralPath marker.txt -Value ran");
        Recipe(new { commands = new Command[] { new("dotnet", ["invalid-build-automation-command"]), new("pwsh", Script: "should-not-run.ps1", Shell: "pwsh") } });
        Assert.Throws<InvalidOperationException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
        Assert.That(File.Exists(Path.Combine(root, "marker.txt")), Is.False);
        var receipt = JsonDocument.Parse(File.ReadAllText(Directory.GetFiles(Path.Combine(root, "artifacts"), "receipt.json", SearchOption.AllDirectories).Single()));
        Assert.That(receipt.RootElement.GetProperty("succeeded").GetBoolean(), Is.False);
    }

    [Test] public void PowerShellNonTerminatingErrorFailsAndTemporaryScriptIsRemoved()
    {
        File.WriteAllText(Path.Combine(root, "error.ps1"), "Write-Error 'expected failure'");
        Recipe(new { commands = new Command[] { new("pwsh", Script: "error.ps1", Shell: "pwsh") } });
        Assert.Throws<InvalidOperationException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
        Assert.That(Directory.GetFiles(Path.Combine(root, "artifacts"), "*.ps1", SearchOption.AllDirectories), Is.Empty);
    }

    [Test] public void StructuredArgumentsPreserveSpacesAndMetacharacters()
    {
        File.WriteAllText(Path.Combine(root, "argument.ps1"), "param([string]$Value)\nSet-Content -LiteralPath argument.txt -Value $Value -NoNewline");
        const string expected = "spaces;$(not code) 'quoted'";
        Recipe(new { commands = new[] { new Command("pwsh", ["-NoProfile", "-File", Path.Combine(root, "argument.ps1"), expected]) } });
        RecipeRunner.Run(root, "recipe.json", "test");
        Assert.That(File.ReadAllText(Path.Combine(root, "argument.txt")), Is.EqualTo(expected));
    }

    [Test] public void InvalidTimeoutIsRejected() => Assert.Throws<ArgumentException>(() => RecipeRunner.Execute("dotnet", ["--version"], root, 0));

    [Test] public void FreshResultsAreVerifiedAndRecorded()
    {
        string fixture = Trx(3, 3, 3, 0);
        File.WriteAllText(Path.Combine(root, "results.ps1"), "New-Item -ItemType Directory results -Force | Out-Null\nCopy-Item -LiteralPath tests.trx -Destination results/fresh.trx");
        Recipe(new { commands = new Command[] { new("pwsh", Script: "results.ps1", Shell: "pwsh") }, results = new[] { "results/**/*.trx" } });
        RecipeRunner.Run(root, "recipe.json", "test");
        var receipt = JsonDocument.Parse(File.ReadAllText(Directory.GetFiles(Path.Combine(root, "artifacts"), "receipt.json", SearchOption.AllDirectories).Single()));
        Assert.That(receipt.RootElement.GetProperty("results")[0].GetProperty("Passed").GetInt64(), Is.EqualTo(3));
    }

    [Test] public void EveryDeclaredSuiteMustProduceResults()
    {
        Trx(3, 3, 3, 0);
        File.WriteAllText(Path.Combine(root, "results.ps1"), "New-Item -ItemType Directory results -Force | Out-Null\nCopy-Item -LiteralPath tests.trx -Destination results/fresh.trx");
        Recipe(new { commands = new Command[] { new("pwsh", Script: "results.ps1", Shell: "pwsh") }, results = new[] { "results/*.trx", "missing/*.trx" } });
        Assert.Throws<InvalidDataException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
    }

    [Test] public void UnknownSchemaIsRejected()
    {
        File.WriteAllText(Path.Combine(root, "recipe.json"), "{\"schema\":2,\"tasks\":{}}");
        Assert.Throws<InvalidDataException>(() => RecipeRunner.Run(root, "recipe.json", "test"));
    }
}
