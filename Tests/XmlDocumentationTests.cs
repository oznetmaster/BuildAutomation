// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using BuildAutomation;
using NUnit.Framework;
using Auditor = BuildAutomation.XmlDocumentation.Program;

public sealed class XmlDocumentationTests
{
    private string root = null!;
    [SetUp] public void Setup() => Directory.CreateDirectory(root = Path.Combine(Path.GetTempPath(), "xml docs " + Guid.NewGuid()));
    [TearDown] public void Cleanup() => Directory.Delete(root, true);

    private string Source(string source, string name = "Api.cs")
    {
        string path = Path.Combine(root, name);
        File.WriteAllText(path, source);
        return path;
    }

    private const string Complete = """
        /// <summary>Stores an item.</summary>
        /// <typeparam name="T">The stored item type.</typeparam>
        /// <param name="item">The initial item.</param>
        public class Box<T>(T item) {
        /// <summary>Gets the stored item.</summary>
        /// <value>The item supplied to the constructor.</value>
        public T Item => item;
        /// <summary>Returns a supplied value.</summary>
        /// <param name="value">The input value.</param>
        /// <returns>The supplied input.</returns>
        public T Echo(T value) => value;
        }
        """;

    [Test] public void CompletePrimaryConstructorAndGenericApiPass() =>
        Assert.That(Auditor.Audit([Source(Complete)]).SelectMany(m => m.Errors), Is.Empty);

    [TestCase("<value>The item supplied to the constructor.</value>", "value")]
    [TestCase("<returns>The supplied input.</returns>", "returns")]
    [TestCase("<param name=\"value\">The input value.</param>", "param value")]
    [TestCase("<typeparam name=\"T\">The stored item type.</typeparam>", "typeparam T")]
    [TestCase("<param name=\"item\">The initial item.</param>", "param item")]
    public void RequiredTagCannotBeRemoved(string fragment, string diagnostic) =>
        Assert.That(Auditor.Audit([Source(Complete.Replace(fragment, ""))]).SelectMany(m => m.Errors), Has.Some.Contains(diagnostic));

    [TestCase("<summary> </summary>")]
    [TestCase("<summary>Broken</returns>")]
    [TestCase("<summary>One.</summary><summary>Two.</summary>")]
    public void InvalidSummaryIsRejected(string comment) =>
        Assert.That(Auditor.Audit([Source("/// " + comment + "\npublic class Api {}")]).SelectMany(m => m.Errors), Is.Not.Empty);

    [Test] public void MisnamedParameterIsRejected() =>
        Assert.That(Auditor.Audit([Source(Complete.Replace("name=\"value\"", "name=\"other\""))]).SelectMany(m => m.Errors), Has.Some.EqualTo("Unknown param name"));

    [Test] public void EmptyPropertyValueIsRejected() =>
        Assert.That(Auditor.Audit([Source(Complete.Replace("The item supplied to the constructor.", " "))]).SelectMany(m => m.Errors), Has.Some.EqualTo("Missing or empty value"));

    [Test] public void InternalTypesAndPrivateInterfaceMembersAreExcluded()
    {
        var result = Auditor.Audit([Source("internal class Hidden { public int Undocumented => 0; }\n/// <summary>Public contract.</summary>\npublic interface IApi { private void Hidden() {} }")]);
        Assert.That(result.Select(m => m.Name), Is.EqualTo(new[] { "IApi" }));
        Assert.That(result.SelectMany(m => m.Errors), Is.Empty);
    }

    [Test] public void PartialTypeDocumentationIsSharedAcrossFiles()
    {
        var result = Auditor.Audit([Source("/// <summary>The API.</summary>\npublic partial class Api {}"), Source("public partial class Api {}", "Other.cs")]);
        Assert.That(result, Has.Count.EqualTo(1));
        Assert.That(result.SelectMany(m => m.Errors), Is.Empty);
    }

    [Test] public void UndocumentedPublicPartialMembersAreStillRejected()
    {
        var result = Auditor.Audit([Source("/// <summary>The API.</summary>\npublic partial class Api {}"), Source("public partial class Api { public int Missing => 0; }", "Other.cs")]);
        Assert.That(result.Single(m => m.Name == "Missing").Errors, Has.Some.EqualTo("Missing XML documentation"));
    }

    [Test] public void FrameworkSymbolsExposeOtherwiseHiddenDocumentationGaps()
    {
        string file = Source("/// <summary>The API.</summary>\npublic class Api {\n#if NET472\npublic int Missing => 0;\n#endif\n}");
        Assert.That(Auditor.Audit([file]).SelectMany(m => m.Errors), Is.Empty);
        Assert.That(Auditor.Audit([file], ["NET472"]).Single(m => m.Name == "Missing").Errors, Is.Not.Empty);
    }

    [Test] public void ExplicitInheritanceAndDocumentedOverridesAreAccepted()
    {
        var result = Auditor.Audit([Source("/// <summary>The API.</summary>\npublic class Api {\n/// <inheritdoc cref=\"System.IDisposable.Dispose\"/>\npublic void Dispose() {}\n/// <inheritdoc/>\npublic override string ToString()=>\"\"; }")]);
        Assert.That(result.SelectMany(m => m.Errors), Is.Empty);
    }

    [Test] public void ImplicitInterfaceInheritanceRequiresAnExplicitSource() =>
        Assert.That(Auditor.Audit([Source("/// <summary>The API.</summary>\npublic class Api {\n/// <inheritdoc/>\npublic void Dispose() {} }")]).SelectMany(m => m.Errors), Is.Not.Empty);

    [Test] public void EmptyProjectListCannotPass() =>
        Assert.Throws<InvalidDataException>(() => XmlDocumentationPolicy.Verify(root, new([])));

    [Test] public void MissingProjectCannotPass() =>
        Assert.Throws<FileNotFoundException>(() => XmlDocumentationPolicy.Verify(root, new(["Missing.csproj"])));

    [Test] public void ProjectMustStayInsideRepository() =>
        Assert.Throws<ArgumentException>(() => XmlDocumentationPolicy.Verify(root, new(["../Other.csproj"])));

    [Test] public void RecipeRunsXmlGateBeforeItsCommands()
    {
        File.WriteAllText(Path.Combine(root, "marker.ps1"), "Set-Content marker.txt ran");
        File.WriteAllText(Path.Combine(root, "recipe.json"), """
            { "schema": 1, "xmlDocumentation": { "projects": ["Missing.csproj"] },
              "tasks": { "check": { "commands": [{ "executable": "pwsh", "script": "marker.ps1", "shell": "pwsh" }] } } }
            """);
        Assert.Throws<FileNotFoundException>(() => RecipeRunner.Run(root, "recipe.json", "check"));
        Assert.That(File.Exists(Path.Combine(root, "marker.txt")), Is.False);
        Assert.That(Directory.GetFiles(Path.Combine(root, "artifacts"), "receipt.json", SearchOption.AllDirectories), Has.Length.EqualTo(1));
    }

    private void Project(string generate = "true", string? additional = null) =>
        File.WriteAllText(Path.Combine(root, "Api.csproj"), $"<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net10.0</TargetFramework><GenerateDocumentationFile>{generate}</GenerateDocumentationFile></PropertyGroup>{additional}</Project>");

    [Test] public void RealProjectEvaluationChecksBothConfigurations()
    {
        Project(); Source(Complete);
        var result = XmlDocumentationPolicy.Verify(root, new(["Api.csproj"]));
        Assert.That(result.Select(r => r.Configuration), Is.EquivalentTo(new[] { "Debug", "Release" }));
        Assert.That(result.All(r => r.Framework == "net10.0" && r.Checked == 3), Is.True);
    }

    [Test] public void DisabledGenerationFailsEvenWithCompleteComments()
    {
        Project("false"); Source(Complete);
        Assert.Throws<InvalidDataException>(() => XmlDocumentationPolicy.Verify(root, new(["Api.csproj"])));
    }

    [Test] public void MissingCompileInputFailsInsteadOfReducingCoverage()
    {
        Project(additional: "<ItemGroup><Compile Include=\"Missing.cs\" /></ItemGroup>"); Source(Complete);
        Assert.Throws<FileNotFoundException>(() => XmlDocumentationPolicy.Verify(root, new(["Api.csproj"])));
    }

    [Test] public void FrameworkSpecificGapFailsRealProjectEvaluation()
    {
        Project(); Source("/// <summary>The API.</summary>\npublic class Api {\n#if NET10_0\npublic int Missing => 0;\n#endif\n}");
        Assert.Throws<InvalidDataException>(() => XmlDocumentationPolicy.Verify(root, new(["Api.csproj"])));
    }
}
