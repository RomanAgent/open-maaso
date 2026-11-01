using System;
using System.Reflection;
using NUnit.Framework;
using UnityEditor.Build;

public sealed class AvatarRetiredAssetBuildGuardTests
{
    private const string Joy = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
    private static Type Guard { get { return Type.GetType("Maaso.Avatar.Editor.AvatarRetiredAssetBuildGuard, Assembly-CSharp-Editor", true); } }
    private static object Call(string name, params object[] args) => Guard.GetMethod(name, BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, args);
    private static T Field<T>(object audit, string name) => (T)audit.GetType().GetField(name).GetValue(audit);

    [TestCase("Assets/MaasoAvatar/Models/Matt/Matt.fbx")]
    [TestCase("Assets/MaasoAvatar/Models/Matt/Generated/Std_Skin_Head.mat")]
    [TestCase("Assets\\MaasoAvatar\\Resources\\MaleCompanion.prefab")]
    [TestCase("./Assets/MaasoAvatar/Resources/MattIdentity.json")]
    [TestCase("Assets/MaasoAvatar/Resources/MattPupilStandard.shader")]
    [TestCase("Assets/MaasoAvatar/Resources/MattPupilUv.cginc")]
    [TestCase("Assets/MaasoAvatar/Shaders/MattTwoSidedCutout.shader")]
    [TestCase("Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Male.prefab")]
    [TestCase("Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Materials/Male/Skin.mat")]
    [TestCase("Assets/Rukha93/ModularAnimeCharacter/Prefabs/M_FullBody.prefab")]
    [TestCase("Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/M_top.010_shirtandtie.fbx")]
    [TestCase("Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/M_bot.004_skinnyjeans.fbx")]
    public void RejectsExactRetiredOfficialAssetPaths(string path) => Assert.That(Call("IsRetiredSourcePath", path), Is.True);

    [TestCase(Joy)]
    [TestCase("Assets/UserModels/Male.prefab")]
    [TestCase("Assets/UserModels/Matt/Matt.fbx")]
    [TestCase("Assets/MaasoAvatar/Models/Matthew/model.fbx")]
    [TestCase("Assets/MaasoAvatar/Resources/MaleCompanionCustom.prefab")]
    [TestCase("Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Female.prefab")]
    [TestCase("Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Materials/Female/Skin.mat")]
    [TestCase("Assets/MaasoAvatar/Animations/Humanoid/Actions/female_start_walking.anim")]
    [TestCase("Assets/Rukha93/ModularAnimeCharacter/Prefabs/HairStyles/C_hair_short.001.prefab")]
    [TestCase("Assets/AnotherVendor/ModularAnime/Male.prefab")]
    [TestCase("")]
    [TestCase(null)]
    public void PreservesFemaleSharedAndUserAssets(string path) => Assert.That(Call("IsRetiredSourcePath", path), Is.False);

    [Test]
    public void AuditDigestIsDeterministicAndRecordsOnlyCompactBuildEvidence()
    {
        const string shared = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        object first = Call("CreateAudit", new[] { shared, Joy, Joy }, "iOS", "build-guid");
        object second = Call("CreateAudit", new[] { Joy, shared }, "iOS", "build-guid");
        Assert.That(Field<int>(first, "sourcePathCount"), Is.EqualTo(2));
        Assert.That(Field<string>(first, "sourcePathListSha256"), Is.EqualTo(Field<string>(second, "sourcePathListSha256")));
        Assert.That(Field<string>(first, "sourcePathListSha256").Length, Is.EqualTo(64));
        Assert.That(Field<string>(first, "target"), Is.EqualTo("iOS"));
        Assert.That(Field<string>(first, "buildGuid"), Is.EqualTo("build-guid"));
        Assert.That(Field<int>(first, "retiredSourceCount"), Is.Zero);
        Assert.That(Field<bool>(first, "retainedJoySourceFound"), Is.True);
        Assert.That(Field<string[]>(first, "retainedJoyEvidencePaths"), Is.EqualTo(new[] { Joy }));
        Assert.DoesNotThrow(() => Call("RequireAllowed", first));
    }

    [Test]
    public void RetiredAndMissingEvidenceFailTheBuild()
    {
        foreach (string[] paths in new[] {
            new[] { Joy, "Assets/MaasoAvatar/Resources/MaleCompanion.prefab" },
            Array.Empty<string>(),
            new[] { "Assets/Shared/SomeShader.shader" },
        })
        {
            object audit = Call("CreateAudit", paths, "iOS", "build-guid");
            var error = Assert.Throws<TargetInvocationException>(() => Call("RequireAllowed", audit));
            Assert.That(error.InnerException, Is.TypeOf<BuildFailedException>());
        }
    }
}
