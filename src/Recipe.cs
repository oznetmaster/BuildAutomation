// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace BuildAutomation;

public sealed record Recipe(int Schema, Dictionary<string, BuildTask> Tasks);
public sealed record BuildTask(Command[] Commands, string[]? Results = null);
public sealed record Command(string Executable, string[]? Arguments = null,
    string? Script = null, string? Shell = null, int TimeoutMinutes = 30);
public sealed record TestResult(string File, long Total, long Executed, long Passed, long Failed, long Skipped);

public static partial class RecipeRunner
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };

    public static string Expand(string value) => EnvironmentVariable().Replace(value, match =>
        Environment.GetEnvironmentVariable(match.Groups[1].Value)
        ?? throw new ArgumentException("Missing build input: " + match.Groups[1].Value));

    public static string Inside(string root, string relative)
    {
        string path = Path.GetFullPath(relative, root);
        string prefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!path.Equals(Path.TrimEndingDirectorySeparator(root), comparison) && !path.StartsWith(prefix, comparison))
            throw new ArgumentException("Recipe paths must stay inside the repository: " + relative);
        return path;
    }

    public static void Run(string root, string recipePath, string taskName)
    {
        string source = Inside(root, recipePath);
        var recipe = JsonSerializer.Deserialize<Recipe>(File.ReadAllText(source), Json)
            ?? throw new InvalidDataException("Empty recipe.");
        if (recipe.Schema != 1) throw new InvalidDataException("Unsupported recipe schema.");
        if (!recipe.Tasks.TryGetValue(taskName, out var task)) throw new ArgumentException("Unknown recipe task: " + taskName);
        if (task.Commands.Length == 0) throw new InvalidDataException("A build task must execute at least one command.");
        // Keep every invocation separate, including concurrent local runs and matrix jobs.
        string output = Path.Combine(root, "artifacts", "build-automation", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        var before = SnapshotResults(root, task.Results);
        var started = DateTimeOffset.UtcNow;
        var commands = new List<object>();
        try
        {
            foreach (var command in task.Commands)
            {
                int index = commands.Count;
                string[] arguments = command.Arguments?.Select(Expand).ToArray() ?? [];
                string executable = command.Executable;
                if (command.Script != null)
                {
                    if (command.Arguments?.Length > 0) throw new InvalidDataException("Script commands cannot also specify arguments.");
                    string script = Inside(root, command.Script);
                    string text = File.ReadAllText(script);
                    // These inputs replace only the original GitHub expression locations.
                    // Values are not printed or written into the receipt.
                    text = Expand(text);
                    string suffix = command.Shell switch { "pwsh" => ".ps1", "bash" => ".sh", _ => throw new InvalidDataException("Use pwsh or bash for scripts.") };
                    string temporary = Path.Combine(output, "step-" + index + suffix);
                    if (command.Shell == "pwsh") text = "$ErrorActionPreference = 'Stop'\n" + text + "\nif (Test-Path -LiteralPath variable:LASTEXITCODE) { exit $LASTEXITCODE }\n";
                    File.WriteAllText(temporary, text);
                    executable = command.Shell!;
                    arguments = command.Shell == "pwsh" ? ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", temporary] : ["--noprofile", "--norc", "-e", "-o", "pipefail", temporary];
                    try { Execute(executable, arguments, root, command.TimeoutMinutes); }
                    finally { File.Delete(temporary); }
                }
                else Execute(executable, arguments, root, command.TimeoutMinutes);
                commands.Add(new { executable = command.Executable, script = command.Script, completedUtc = DateTimeOffset.UtcNow });
            }
            var results = ReadFreshResults(root, task.Results, before);
            WriteReceipt(output, new { schema = 1, task = taskName, recipeSha256 = Hash(source), startedUtc = started,
                completedUtc = DateTimeOffset.UtcNow, succeeded = true, commands, results, publication = false });
        }
        catch (Exception error)
        {
            WriteReceipt(output, new { schema = 1, task = taskName, recipeSha256 = Hash(source), startedUtc = started,
                completedUtc = DateTimeOffset.UtcNow, succeeded = false, commands, errorType = error.GetType().Name, publication = false });
            throw;
        }
        Console.WriteLine("Build receipt: " + Path.Combine(output, "receipt.json"));
    }

    public static void Execute(string executable, string[] arguments, string root, int timeoutMinutes)
    {
        if (timeoutMinutes is < 1 or > 120) throw new ArgumentException("Command timeout must be 1 to 120 minutes.");
        // Preserve child stdout/stderr and GitHub workflow commands; do not log argument values.
        var start = new ProcessStartInfo(executable) { WorkingDirectory = root, UseShellExecute = false };
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start " + executable);
        if (!process.WaitForExit(checked(timeoutMinutes * 60 * 1000)))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            throw new TimeoutException("Build command timed out: " + executable);
        }
        if (process.ExitCode != 0) throw new InvalidOperationException($"{executable} failed with exit code {process.ExitCode}.");
    }

    public static TestResult ReadTrx(string file)
    {
        var document = XDocument.Load(file);
        var counters = document.Descendants().Single(e => e.Name.LocalName == "Counters");
        long Number(string name) => long.Parse(counters.Attribute(name)?.Value ?? throw new InvalidDataException("Missing TRX counter: " + name), CultureInfo.InvariantCulture);
        long total = Number("total"), executed = Number("executed"), passed = Number("passed"), failed = Number("failed");
        string outcome = document.Descendants().Single(e => e.Name.LocalName == "ResultSummary").Attribute("outcome")?.Value ?? "";
        if (total <= 0 || passed <= 0 || failed != 0 || passed != executed || executed > total || outcome != "Completed")
            throw new InvalidDataException("Unsuccessful or empty TRX: " + file);
        return new(file, total, executed, passed, failed, total - executed);
    }

    private static string[] ResultFiles(string root, string[]? patterns) => (patterns ?? []).SelectMany(pattern =>
    {
        string expanded = Expand(pattern).Replace('\\', '/');
        int wildcard = expanded.IndexOfAny(['*', '?']);
        string directory = wildcard < 0 ? Path.GetDirectoryName(expanded)! : expanded[..expanded.LastIndexOf('/', wildcard)];
        string basePath = Inside(root, directory.Length == 0 ? "." : directory);
        // Only the portable directory/**/*.trx and directory/*.trx forms are supported.
        string tail = expanded[(directory.Length + 1)..];
        if (tail is not "*.trx" and not "**/*.trx") throw new ArgumentException("Unsupported result glob: " + pattern);
        return Directory.Exists(basePath) ? Directory.GetFiles(basePath, "*.trx", tail.StartsWith("**/") ? SearchOption.AllDirectories : SearchOption.TopDirectoryOnly) : [];
    }).Distinct().ToArray();

    private static Dictionary<string, (long ticks, string hash)> SnapshotResults(string root, string[]? patterns) =>
        ResultFiles(root, patterns).ToDictionary(file => file, file => (File.GetLastWriteTimeUtc(file).Ticks, Hash(file)));

    private static TestResult[] ReadFreshResults(string root, string[]? patterns, Dictionary<string, (long ticks, string hash)> before)
    {
        if (patterns == null || patterns.Length == 0) return [];
        var fresh = new List<string>();
        foreach (string pattern in patterns)
        {
            var current = ResultFiles(root, [pattern]).Where(file => !before.TryGetValue(file, out var previous) || previous != (File.GetLastWriteTimeUtc(file).Ticks, Hash(file))).ToArray();
            if (current.Length == 0) throw new InvalidDataException("No fresh TRX results were produced for " + pattern);
            fresh.AddRange(current);
        }
        return fresh.Distinct().Select(ReadTrx).ToArray();
    }

    private static string Hash(string path) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    private static void WriteReceipt(string output, object data) => File.WriteAllText(Path.Combine(output, "receipt.json"), JsonSerializer.Serialize(data, Json));
    [GeneratedRegex(@"\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}", RegexOptions.CultureInvariant)]
    private static partial Regex EnvironmentVariable();
}
