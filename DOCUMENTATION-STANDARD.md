# Pages documentation standard, version 1

All maintained client/library Pages sites use DocFX's built-in `default` plus `modern` templates, a local tool manifest pinned to DocFX 2.81.0, and the same visible layout:

- Home: repository-specific introduction and capabilities.
- Guides: a common landing page and the repository's existing guides.
- API Reference: a common landing page linking every existing API output group.
- GitHub: the repository source.
- NuGet: the maintainer's package profile.

Site title and app name use the repository's canonical product name. Search is enabled. The common footer is `Copyright (c) 2026 Neil Colvin.` Existing conceptual pages, public API groups, attribution, licensing and compatibility statements remain repository-owned. Existing page URLs are preserved by adding navigation landing pages instead of relocating content.

The repository's `documentation` Cake recipe owns build/generation commands and declares its config, site directory and title. The shared `DocumentationPolicy` rejects missing landing pages, API output, search index or required layout settings. Existing stronger XML coverage, rendered-summary and warning checks remain in place.

GitHub Actions owns Pages upload/deployment, environment protection, permissions, runner selection and concurrency. Documentation generation is available locally through `build/Invoke.ps1 -Task documentation` (Tesla's shared wrapper is `build/Invoke-Shared.ps1`). Running that local target never publishes the site.

Source extraction differs legitimately between projects and reflection-based metadata. It stays repository-specific. A site must build successfully before publication; a blank API section is not considered a successful documentation build.

References: [DocFX templates](https://dotnet.github.io/docfx/docs/template.html), [navigation and reference TOCs](https://dotnet.github.io/docfx/docs/table-of-contents.html).


## Strict XML API documentation

Library recipes declare their production projects in the top-level `xmlDocumentation.projects` list. Every shared task checks those projects before executing its commands. A dedicated CI workflow and an unconditional check in each publishing job apply the same standard even when desktop or processor results are reused.

The check evaluates MSBuild Compile inputs and runs the SDK's `AddImplicitDefineConstants` target to obtain actual framework/platform symbols, alongside project-defined symbols. It audits every target framework in both Debug and Release. Public and protected authored declarations require non-empty summaries, matching parameter and type-parameter descriptions, return descriptions for non-void methods (including asynchronous methods), and `<value>` descriptions for properties and indexers. Malformed XML, wrong parameter names, duplicate tags and empty content fail. Partial types share their type documentation, while their public members remain individually checked. Overrides must be documented; explicit `<inheritdoc cref="..."/>` is accepted. Compiler XML diagnostics are errors in the production projects, including reference-resolution errors.

Descriptions must explain the actual API contract, including units, null/default behavior and cancellation where relevant. A complete existing property summary can supply a value description; build tooling does not generate or invent documentation content.

DocFX uses explicit existing production-project inputs and the shared policy rejects empty rendered Property Value descriptions. Generated wire-contract references can have a narrowly named `generatedApiPrefixes` exception: the generated types remain visible, and the exemption must be documented by the repository. This is distinct from authored API coverage. SDK/build-generated files that are not authored Compile inputs are outside the source-comment audit; normal compilation still checks their XML diagnostics.

Ordinary IDE/product builds do not download Cake. They generate XML and enforce compiler XML diagnostics directly; `./build/Invoke.ps1 -Task xml-documentation` additionally runs the full shared content audit. A receipt records project, framework, configuration and declaration counts without claiming runtime tests were performed.
