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
