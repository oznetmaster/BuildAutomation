using System.Text.Json;
using System.Xml.Linq;

using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace BuildAutomation.XmlDocumentation;

public static class Program
	{
	private static bool External (SyntaxNode node)
		{
		if (node is not MemberDeclarationSyntax member)
			return false;
		if (member is EnumMemberDeclarationSyntax)
			return External (member.Parent!);
		if (member.Modifiers.Any (SyntaxKind.PrivateKeyword))
			return false;
		bool visible = member.Modifiers.Any (SyntaxKind.PublicKeyword) || member.Modifiers.Any (SyntaxKind.ProtectedKeyword) || member.Parent is InterfaceDeclarationSyntax;
		if (!visible)
			return false;
		for (var parent = member.Parent; parent != null; parent = parent.Parent)
			if (parent is BaseTypeDeclarationSyntax type && !External (type))
				return false;
		return true;
		}
	private static string Name (SyntaxNode node) => node switch
		{
			BaseTypeDeclarationSyntax n => n.Identifier.ValueText,
			MethodDeclarationSyntax n => n.Identifier.ValueText,
			ConstructorDeclarationSyntax n => ".ctor",
			PropertyDeclarationSyntax n => n.Identifier.ValueText,
			EnumMemberDeclarationSyntax n => n.Identifier.ValueText,
			DelegateDeclarationSyntax n => n.Identifier.ValueText,
			FieldDeclarationSyntax n => string.Join (",", n.Declaration.Variables.Select (v => v.Identifier.ValueText)),
			EventDeclarationSyntax n => n.Identifier.ValueText,
			EventFieldDeclarationSyntax n => string.Join (",", n.Declaration.Variables.Select (v => v.Identifier.ValueText)),
			IndexerDeclarationSyntax => "this",
			OperatorDeclarationSyntax n => "operator " + n.OperatorToken.ValueText,
			ConversionOperatorDeclarationSyntax n => "operator " + n.Type.ToString (),
			_ => ""
			};
	private static string[] Parameters (SyntaxNode node) => (node switch
		{
			MethodDeclarationSyntax n => n.ParameterList.Parameters,
			ConstructorDeclarationSyntax n => n.ParameterList.Parameters,
			DelegateDeclarationSyntax n => n.ParameterList.Parameters,
			TypeDeclarationSyntax n => n.ParameterList?.Parameters ?? default,
			IndexerDeclarationSyntax n => n.ParameterList.Parameters,
			OperatorDeclarationSyntax n => n.ParameterList.Parameters,
			ConversionOperatorDeclarationSyntax n => n.ParameterList.Parameters,
			_ => default
			}).Select (p => p.Identifier.ValueText).ToArray ();
	private static string[] TypeParameters (SyntaxNode node) => (node switch
		{
			TypeDeclarationSyntax n => n.TypeParameterList?.Parameters ?? default,
			MethodDeclarationSyntax n => n.TypeParameterList?.Parameters ?? default,
			DelegateDeclarationSyntax n => n.TypeParameterList?.Parameters ?? default,
			_ => default
			}).Select (p => p.Identifier.ValueText).ToArray ();
	private static string Kind (SyntaxNode n) => n switch { BaseTypeDeclarationSyntax => "type", PropertyDeclarationSyntax or IndexerDeclarationSyntax => "property", EnumMemberDeclarationSyntax => "enum", _ => "member" };
	private static bool Returns (SyntaxNode n) => n switch { MethodDeclarationSyntax m => m.ReturnType.ToString () != "void", DelegateDeclarationSyntax d => d.ReturnType.ToString () != "void", OperatorDeclarationSyntax or ConversionOperatorDeclarationSyntax => true, _ => false };
	private static XElement? Documentation (SyntaxNode n)
		{
		var trivia = n.GetLeadingTrivia ().Select (t => t.GetStructure ()).OfType<DocumentationCommentTriviaSyntax> ().ToArray ();
		if (trivia.Length == 0)
			return null;
		string xml = string.Join ("\n", trivia.Select (t => string.Join ("\n", t.ToFullString ().Split ('\n').Select (l => l.TrimStart ().StartsWith ("///", StringComparison.Ordinal) ? l.TrimStart ()[3..] : l))));
		return XElement.Parse ("<member>" + xml + "</member>");
		}
	private static List<string> Validate (SyntaxNode n)
		{
		var errors = new List<string> ();
		XElement? doc;
		try
			{
			doc = Documentation (n);
			}
		catch (Exception e) when (e is System.Xml.XmlException) { return ["Malformed XML documentation"]; }
		if (doc == null)
			return ["Missing XML documentation"];
		if (doc.Element ("inheritdoc") is XElement inherited)
			{
			if (string.IsNullOrWhiteSpace ((string?)inherited.Attribute ("cref")) && !(n is MemberDeclarationSyntax member && member.Modifiers.Any (SyntaxKind.OverrideKeyword)))
				errors.Add ("inheritdoc needs an explicit cref or an override");
			return errors;
			}
		Require ("summary");
		foreach (var p in Parameters (n))
			Require ("param", p);
		foreach (var p in TypeParameters (n))
			Require ("typeparam", p);
		foreach (var tag in doc.Elements ().Where (e => e.Name is { LocalName: "param" or "typeparam" }))
			if (!(tag.Name.LocalName == "param" ? Parameters (n) : TypeParameters (n)).Contains ((string?)tag.Attribute ("name")))
				errors.Add ("Unknown " + tag.Name + " name");
		if (Returns (n))
			Require ("returns");
		if (Kind (n) == "property")
			Require ("value");
		foreach (var group in doc.Elements ().Where (e => e.Name.LocalName is "summary" or "returns" or "value").GroupBy (e => e.Name.LocalName))
			if (group.Count () > 1)
				errors.Add ("Duplicate " + group.Key);
		return errors;
		void Require (string tag, string? name = null)
			{
			var found = doc.Elements (tag).Where (e => name == null || (string?)e.Attribute ("name") == name).ToArray ();
			if (found.Length != 1 || string.IsNullOrWhiteSpace (found[0].Value) && !found[0].Elements ().Any ())
				errors.Add ("Missing or empty " + tag + (name == null ? "" : " " + name));
			}
		}
	private static bool HasDocumentation (SyntaxNode n)
		{
		try
			{
			return Documentation (n) != null;
			}
		catch (System.Xml.XmlException) { return true; } // Validate reports malformed comments without crashing the inventory.
		}
	private static string Key (SyntaxNode n) => string.Join (".", n.Ancestors ().Reverse ().Where (a => a is BaseNamespaceDeclarationSyntax or BaseTypeDeclarationSyntax).Select (a => a is BaseNamespaceDeclarationSyntax ns ? ns.Name.ToString () : Name (a) + "`" + TypeParameters (a).Length).Append (Name (n) + "`" + TypeParameters (n).Length));
	private static IEnumerable<SyntaxNode> Nodes (string source, IEnumerable<string>? symbols = null) => CSharpSyntaxTree.ParseText (source, new CSharpParseOptions (LanguageVersion.Latest, DocumentationMode.Diagnose, preprocessorSymbols: symbols)).GetRoot ().DescendantNodes ().Where (n => Name (n) != "" && External (n));
	private static void SelfTest ()
		{
		var bad = Nodes ("public class Missing { public string Echo(string text)=>text; }").ToArray ();
		if (!bad.All (n => Validate (n).Count > 0))
			throw new Exception ("Missing comments were accepted.");
		const string valid = """
            /// <summary>Echo operations.</summary>
            public class Echo {
            /// <summary>Returns the input.</summary>
            /// <param name="text">Input text.</param>
            /// <returns>The supplied text.</returns>
            public string Run(string text)=>text;
            /// <summary>Gets the count.</summary>
            /// <value>The current count.</value>
            public int Count=>0;
            }
            """;
		if (Nodes (valid).Any (n => Validate (n).Count != 0))
			throw new Exception ("Complete comments were rejected.");
		foreach (string fragment in new[] { "<param name=\"text\">Input text.</param>", "<returns>The supplied text.</returns>", "<value>The current count.</value>" })
			if (!Nodes (valid.Replace (fragment, "")).Any (n => Validate (n).Count != 0))
				throw new Exception ("An incomplete member was accepted.");
		if (Nodes ("internal class Hidden { public int Undocumented=>0; }").Any ())
			throw new Exception ("Internal implementation leaked into public coverage.");
		const string generic = """
            /// <summary>Stores an item.</summary>
            /// <typeparam name="T">The item type.</typeparam>
            /// <param name="item">The initial item.</param>
            public class Box<T>(T item) {
            /// <summary>Gets the item.</summary>
            /// <value>The retained item.</value>
            public T Item=>item;
            }
            """;
		if (Nodes (generic).Any (n => Validate (n).Count != 0))
			throw new Exception ("A documented primary constructor was rejected.");
		foreach (string fragment in new[] { "<typeparam name=\"T\">The item type.</typeparam>", "<param name=\"item\">The initial item.</param>" })
			if (!Nodes (generic.Replace (fragment, "")).Any (n => Validate (n).Count != 0))
				throw new Exception ("Generic or primary-constructor coverage was not enforced.");
		foreach (string source in new[] { "/// <summary>Broken</value>\npublic class Broken {}", "/// <inheritdoc/>\npublic class Empty {}", "/// <summary> </summary>\npublic class Empty {}" })
			if (!Nodes (source).Any (n => Validate (n).Count != 0))
				throw new Exception ("Invalid documentation was accepted.");
		if (Nodes ("public interface ITest { private void Hidden() {} }").Any (n => Name (n) == "Hidden"))
			throw new Exception ("Private interface implementation leaked into coverage.");
		if (!Nodes ("/// <inheritdoc/>\npublic class Derived { public override string ToString()=>\"\"; }").Where (n => Name (n) == "ToString").All (n => Validate (n).Count != 0))
			throw new Exception ("Undocumented overrides were accepted.");
		Console.WriteLine ("Documentation audit self-tests passed (missing tags, primary constructors, generics, malformed XML and visibility).");
		}

    public sealed record MemberResult(string Path, string Key, string Name, string Kind, int Line,
        int Start, string[] Parameters, string[] TypeParameters, bool Returns, bool HasDocs,
        List<string> Errors, string Source);

    public static IReadOnlyList<MemberResult> Audit(IEnumerable<string> files, IEnumerable<string>? symbols = null)
    {
        var items = files.SelectMany(file => Nodes(File.ReadAllText(file), symbols)
            .Select(n => new { File = System.IO.Path.GetFullPath(file), Node = n, Key = Key(n) })).ToArray();
        var documentedPartials = items.Where(i => i.Node is TypeDeclarationSyntax t &&
            t.Modifiers.Any(SyntaxKind.PartialKeyword) && HasDocumentation(i.Node)).Select(i => i.Key).ToHashSet();
        return items.Where(i => !(i.Node is TypeDeclarationSyntax t && t.Modifiers.Any(SyntaxKind.PartialKeyword)
            && !HasDocumentation(i.Node) && documentedPartials.Contains(i.Key)))
            .Select(i => new MemberResult(i.File, i.Key, Name(i.Node), Kind(i.Node),
                i.Node.GetLocation().GetLineSpan().StartLinePosition.Line + 1, i.Node.SpanStart,
                Parameters(i.Node), TypeParameters(i.Node), Returns(i.Node), HasDocumentation(i.Node),
                Validate(i.Node), i.Node.ToFullString())).ToArray();
    }

	public static int Main (string[] args)
		{
		if (args.Contains ("--self-test"))
			{
			SelfTest ();
			return 0;
			}
		bool inventory = args.Contains ("--inventory");
		var files = args.Where (a => !a.StartsWith ("--", StringComparison.Ordinal)).SelectMany (path => Directory.Exists (path) ? Directory.EnumerateFiles (path, "*.cs", SearchOption.AllDirectories) : [path]).Where (p => !p.Split (Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any (s => s is "bin" or "obj")).Distinct ().ToArray ();
		if (files.Length == 0)
			{
			Console.Error.WriteLine ("Supply at least one C# source file or directory. No files were audited.");
			return 2;
			}
		string[] symbols = args.Where (a => a.StartsWith ("--define=", StringComparison.Ordinal)).SelectMany (a => a[9..].Split (';', StringSplitOptions.RemoveEmptyEntries)).ToArray ();
        var results = Audit (files, symbols);
        if (args.Contains ("--context"))
            {
            Console.WriteLine (JsonSerializer.Serialize (results.Where (r => r.Errors.Count != 0), new JsonSerializerOptions { WriteIndented = true }));
            return 0;
            }
		Console.WriteLine (JsonSerializer.Serialize (new
			{
			Checked = results.Count,
			Failed = results.Count (r => r.Errors.Count != 0),
			Members = inventory ? results : results.Where (r => r.Errors.Count != 0).ToArray ()
			}, new JsonSerializerOptions { WriteIndented = true }));
		return results.Any (r => r.Errors.Count != 0) ? 1 : 0;
		}
	}
