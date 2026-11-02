// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using BuildAutomation;
using NUnit.Framework;
using System.Text.Json;

public sealed class DocumentationTests
{
    private string root = null!;
    [SetUp] public void Setup()
    {
        root=Path.Combine(Path.GetTempPath(),"documentation-policy-"+Guid.NewGuid());
        Directory.CreateDirectory(Path.Combine(root,"docs"));
        File.WriteAllText(Path.Combine(root,"docs","toc.yml"),string.Join("\n",new[]{"Home","Guides","API Reference","GitHub","NuGet"}.Select(n=>"- name: "+n))+"\n");
        foreach(string page in new[]{"index.html","guides/index.html","reference/index.html","api/Client.html"})
        {
            string path=Path.Combine(root,"site",page);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,"<html>rendered</html>");
        }
        File.WriteAllText(Path.Combine(root,"site","index.json"),"{\"index.html\":{\"title\":\"Example\"}}");
        Config();
    }
    [TearDown] public void Cleanup()=>Directory.Delete(root,true);
    private void Config(bool search=true,string footer=DocumentationPolicy.Footer,string[]? templates=null)=>
        File.WriteAllText(Path.Combine(root,"docs","docfx.json"),JsonSerializer.Serialize(new {metadata=new[]{new{dest="api"}},build=new{template=templates??["default","modern"],globalMetadata=new{_appTitle="Example",_appName="Example",_appFooter=footer,_enableSearch=search}}}));
    private void Verify()=>DocumentationPolicy.Verify(root,new("docs/docfx.json","site","Example"));
    [Test] public void CompleteGeneratedSitePasses()=>Assert.DoesNotThrow(Verify);
    [Test] public void DisabledSearchFails(){Config(search:false);Assert.Throws<InvalidDataException>(Verify);}
    [Test] public void DifferentTemplateFails(){Config(templates:["default"]);Assert.Throws<InvalidDataException>(Verify);}
    [Test] public void MissingGuideLandingPageFails(){File.Delete(Path.Combine(root,"site/guides/index.html"));Assert.Throws<InvalidDataException>(Verify);}
    [Test] public void EmptySearchIndexFails(){File.WriteAllText(Path.Combine(root,"site/index.json"),"{}");Assert.Throws<InvalidDataException>(Verify);}
    [Test] public void MissingApiOutputFails(){File.Delete(Path.Combine(root,"site/api/Client.html"));Assert.Throws<InvalidDataException>(Verify);}
    [Test] public void MissingNavigationFails(){File.WriteAllText(Path.Combine(root,"docs/toc.yml"),"- name: Home\n");Assert.Throws<InvalidDataException>(Verify);}
}
