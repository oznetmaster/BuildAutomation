// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Net;

namespace BuildAutomation;

public sealed record DocumentationSettings(string Config, string Site, string Title, string[]? GeneratedApiPrefixes = null);

public static class DocumentationPolicy
{
    public const string Footer = "Copyright (c) 2026 Neil Colvin.";
    public static void Verify(string root, DocumentationSettings settings)
    {
        string configPath = RecipeRunner.Inside(root, settings.Config);
        string site = RecipeRunner.Inside(root, settings.Site);
        using var config = JsonDocument.Parse(File.ReadAllText(configPath));
        var build = config.RootElement.GetProperty("build");
        var templates = build.GetProperty("template").EnumerateArray().Select(t => t.GetString()).ToArray();
        if (!templates.SequenceEqual(["default", "modern"])) throw new InvalidDataException("Pages must use the shared default/modern template baseline.");
        var metadata = build.GetProperty("globalMetadata");
        if (metadata.GetProperty("_appTitle").GetString() != settings.Title || metadata.GetProperty("_appName").GetString() != settings.Title ||
            metadata.GetProperty("_appFooter").GetString() != Footer || !metadata.GetProperty("_enableSearch").GetBoolean())
            throw new InvalidDataException("Pages title, name, footer or search settings differ from the shared baseline.");
        string toc = File.ReadAllText(Path.Combine(Path.GetDirectoryName(configPath)!, "toc.yml"));
        foreach (string name in new[] { "Home", "Guides", "API Reference", "GitHub", "NuGet" })
            if (!toc.Contains("- name: " + name + "\n", StringComparison.Ordinal) && !toc.Contains("- name: " + name + "\r\n", StringComparison.Ordinal))
                throw new InvalidDataException("Missing common navigation entry: " + name);
        foreach (string page in new[] { "index.html", "guides/index.html", "reference/index.html" })
        {
            string path = RecipeRunner.Inside(site, page);
            if (!File.Exists(path) || new FileInfo(path).Length == 0) throw new InvalidDataException("Missing generated documentation page: " + page);
        }
        string searchPath = Path.Combine(site, "index.json");
        using var search = JsonDocument.Parse(File.ReadAllText(searchPath));
        if (search.RootElement.ValueKind != JsonValueKind.Object || !search.RootElement.EnumerateObject().Any())
            throw new InvalidDataException("Generated documentation has an empty search index.");
        foreach (var group in config.RootElement.GetProperty("metadata").EnumerateArray())
        {
            if (!group.TryGetProperty("src", out var inputs) || inputs.GetArrayLength() == 0)
                throw new InvalidDataException("API metadata must declare source inputs.");
            foreach (var input in inputs.EnumerateArray())
            {
                if (input.TryGetProperty("cwd", out _)) throw new InvalidDataException("DocFX metadata inputs use src, not cwd.");
                string inputRoot = Path.GetFullPath(input.TryGetProperty("src", out var src) ? src.GetString() ?? "." : ".", Path.GetDirectoryName(configPath)!);
                foreach (var file in input.GetProperty("files").EnumerateArray())
                {
                    string pattern = file.GetString() ?? throw new InvalidDataException("Empty API source path.");
                    if (pattern.Contains('*') || pattern.Contains('?')) throw new InvalidDataException("Declare explicit production project paths for API metadata.");
                    if (!File.Exists(Path.GetFullPath(pattern, inputRoot)))
                        throw new InvalidDataException("Missing API metadata input: " + pattern);
                }
            }
            string destination = group.GetProperty("dest").GetString() ?? throw new InvalidDataException("API destination is required.");
            string api = RecipeRunner.Inside(site, destination);
            if (!Directory.Exists(api) || !Directory.EnumerateFiles(api, "*.html", SearchOption.AllDirectories).Any(p => !Path.GetFileName(p).Equals("toc.html", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("No generated API pages for " + destination);
            foreach (string page in Directory.EnumerateFiles(api, "*.html", SearchOption.AllDirectories))
            {
                // Generated wire-contract classes have no authored value descriptions. Keep their
                // reference visible, with an explicit per-repository exception to this content check.
                if ((settings.GeneratedApiPrefixes ?? []).Any(prefix => Path.GetFileName(page).StartsWith(prefix, StringComparison.Ordinal))) continue;
                foreach (Match match in Regex.Matches(File.ReadAllText(page), @"<h4\b[^>]*>\s*Property Value\s*</h4>\s*<dl\b[^>]*>\s*<dt>.*?</dt>\s*<dd>(.*?)</dd>", RegexOptions.Singleline))
                    if (string.IsNullOrWhiteSpace(WebUtility.HtmlDecode(Regex.Replace(match.Groups[1].Value, "<[^>]+>", ""))))
                        throw new InvalidDataException("Generated property value description is empty: " + Path.GetRelativePath(site, page));
            }
        }
        Console.WriteLine("Verified common Pages layout, navigation, search and every API output group.");
    }
}
