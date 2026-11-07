using System;
using System.Reflection;
using NUnit.Framework;

public sealed class OfflineSceneBuildDependencyTests
{
    private static bool Requires(string[] paths, bool mesh = false, bool receipt = false)
    {
        var type = Type.GetType("Maaso.Editor.DeskWorkMeshResourceBuilder, Assembly-CSharp-Editor", true);
        return (bool)type.GetMethod("RequiresDeskMesh", BindingFlags.Static | BindingFlags.NonPublic)
            .Invoke(null, new object[] { paths, mesh, receipt });
    }

    [Test]
    public void FreeAvatarAndPrimitiveSceneDoNotRequireUnshippedCoastalSource()
    {
        Assert.That(Requires(new[] { "Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm" }), Is.False);
    }

    [TestCase("Assets/MaasoWorld/PersonalSpace/CoastalV4/PersonalSpaceV4.fbx")]
    [TestCase("Assets/MaasoWorld/Resources/MaasoDeskWorkMesh.asset")]
    [TestCase("Assets/MaasoWorld/Resources/MaasoDeskWorkMeshReceipt.json")]
    public void ActualCoastalDependenciesStillRequireReviewedSource(string path)
    {
        Assert.That(Requires(new[] { path }), Is.True);
    }

    [Test]
    public void ExistingResourcesStillRequireValidationEvenWithoutSceneReferences()
    {
        Assert.That(Requires(Array.Empty<string>(), mesh: true), Is.True);
        Assert.That(Requires(Array.Empty<string>(), receipt: true), Is.True);
    }
}
