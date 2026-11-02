// Copyright (c) 2026 Neil Colvin. MIT License; see LICENSE.
using Cake.Common;
using Cake.Core;
using Cake.Frosting;
using BuildAutomation;

return new CakeHost().UseContext<RepositoryContext>().Run(args);

public sealed class RepositoryContext : FrostingContext
{
    public RepositoryContext(ICakeContext context) : base(context) { }
    public void ExecuteRecipe() => RecipeRunner.Run(
        Path.GetFullPath(this.Argument("root", System.Environment.CurrentDirectory)),
        this.Argument("recipe", "build/recipe.json"),
        this.Argument<string>("task"));
}

[TaskName("Run")]
public sealed class RunRecipe : FrostingTask<RepositoryContext>
{
    public override void Run(RepositoryContext context) => context.ExecuteRecipe();
}
