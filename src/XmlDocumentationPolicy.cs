// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using System.Diagnostics;
using System.Text.Json;
using Auditor = BuildAutomation.XmlDocumentation.Program;

namespace BuildAutomation;

public sealed record XmlDocumentationSettings(string[] Projects);
public sealed record XmlDocumentationResult(string Project, string Framework, string Configuration, int Checked);

/// <summary>Checks the public source API selected by each project's actual MSBuild settings.</summary>
public static class XmlDocumentationPolicy
{
    private static JsonDocument Evaluate(string root, string project, string? framework, string configuration, bool items)
    {
        var start = new ProcessStartInfo("dotnet")
        {
            WorkingDirectory = root, UseShellExecute = false,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (string value in new[] { "msbuild", project, "-nologo", "-p:Configuration=" + configuration,
            "-p:EnableWindowsTargeting=true",
            "-getProperty:TargetFrameworks,TargetFramework,DefineConstants,GenerateDocumentationFile,WarningsAsErrors,NoWarn" })
            start.ArgumentList.Add(value);
        if (framework != null) start.ArgumentList.Add("-p:TargetFramework=" + framework);
        if (items)
        {
            // The SDK adds NET472/NET10_0 and platform symbols in a target, not at evaluation time.
            // Run that target without compiling, restoring, or invoking product packaging targets.
            start.ArgumentList.Add("-target:AddImplicitDefineConstants");
            start.ArgumentList.Add("-getItem:Compile");
        }
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not evaluate XML documentation inputs.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(120_000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("XML documentation project evaluation timed out: " + project);
        }
        string text = output.GetAwaiter().GetResult();
        string stderr = error.GetAwaiter().GetResult();
        if (process.ExitCode != 0) throw new InvalidOperationException("XML documentation project evaluation failed: " + project + "\n" + text + stderr);
        return JsonDocument.Parse(text);
    }

    public static IReadOnlyList<XmlDocumentationResult> Verify(string root, XmlDocumentationSettings settings)
    {
        if (settings.Projects.Length == 0) throw new InvalidDataException("XML documentation must declare production projects.");
        var results = new List<XmlDocumentationResult>();
        foreach (string relative in settings.Projects)
        {
            string project = RecipeRunner.Inside(root, relative);
            if (!File.Exists(project)) throw new FileNotFoundException("Missing XML documentation project.", project);
            using var outer = Evaluate(root, project, null, "Release", false);
            var props = outer.RootElement.GetProperty("Properties");
            string target = props.GetProperty("TargetFrameworks").GetString() ?? "";
            if (target.Length == 0) target = props.GetProperty("TargetFramework").GetString() ?? "";
            string[] frameworks = target.Split(';', StringSplitOptions.RemoveEmptyEntries);
            if (frameworks.Length == 0) throw new InvalidDataException("No target frameworks for XML documentation: " + relative);
            foreach (string framework in frameworks)
            foreach (string configuration in new[] { "Debug", "Release" })
            {
                using var evaluated = Evaluate(root, project, framework, configuration, true);
                var properties = evaluated.RootElement.GetProperty("Properties");
                if (!string.Equals(properties.GetProperty("GenerateDocumentationFile").GetString(), "true", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException($"XML documentation generation is disabled: {relative} ({configuration}/{framework}).");
                string[] defines = (properties.GetProperty("DefineConstants").GetString() ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries);
                string[] files = evaluated.RootElement.GetProperty("Items").GetProperty("Compile").EnumerateArray()
                    .Select(item => item.GetProperty("FullPath").GetString() ?? throw new InvalidDataException("Missing Compile path."))
                    .Distinct().ToArray();
                if (files.Length == 0) throw new InvalidDataException("No C# Compile inputs for XML documentation: " + relative);
                foreach (string file in files)
                    if (!File.Exists(file)) throw new FileNotFoundException("Missing C# Compile input for XML documentation.", file);
                var members = Auditor.Audit(files, defines);
                if (members.Count == 0) throw new InvalidDataException("No visible API declarations for XML documentation: " + relative);
                var failures = members.Where(m => m.Errors.Count != 0).ToArray();
                foreach (var failure in failures)
                    Console.Error.WriteLine($"{failure.Path}({failure.Line}): XML documentation: {string.Join("; ", failure.Errors)} [{failure.Key}]");
                if (failures.Length != 0)
                    throw new InvalidDataException($"Incomplete XML documentation: {relative} ({configuration}/{framework}), {failures.Length} declarations.");
                results.Add(new(relative, framework, configuration, members.Count));
                Console.WriteLine($"XML documentation: {relative} ({configuration}/{framework}): {members.Count} declarations verified.");
            }
        }
        return results;
    }
}
