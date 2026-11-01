using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;

public sealed class RetiredOfficialAvatarResourcesTests
{
    private static Type Policy => Type.GetType("Maaso.Avatar.RetiredOfficialAvatarResources, Assembly-CSharp", true);
    private static object Call(string name, params object[] args) => Policy.GetMethod(name,
        BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, args);

    [TestCase("masso.bundled.matt", "unity://masso/avatar_matt", true)]
    [TestCase("modular-anime-male", "https://cdn.example.com/model.bundle", true)]
    [TestCase("masso.official.modular-male", "https://cdn.example.com/model.bundle", true)]
    [TestCase("uploaded-male", "https://cdn.example.com/user.bundle", false)]
    [TestCase("masso.bundled.agent", "unity://masso/avatar_agent", false)]
    public void RetirementUsesExactProductIdentity(string key, string url, bool retired) =>
        Assert.That(Call("IsRetiredDescriptor", key, url), Is.EqualTo(retired));

    [Test]
    public void PackagedMaleResourcesAreAbsentAndJoySharedControllerRemain()
    {
        Assert.That(Resources.Load<GameObject>("MaleCompanion"), Is.Null);
        Assert.That(Resources.Load<TextAsset>("MattIdentity"), Is.Null);
        Assert.That(Resources.Load<Shader>("MattPupilStandard"), Is.Null);
        Assert.That(Directory.Exists("Assets/MaasoAvatar/Models/Matt") &&
            Directory.EnumerateFiles("Assets/MaasoAvatar/Models/Matt", "*", SearchOption.AllDirectories).Any(), Is.False);
        Assert.That(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"), Is.Not.Null);
        Assert.That(AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>("Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller"), Is.Not.Null);
    }

    [Test]
    public void CacheCleanupRequiresAnExactPublishedDigestAndNeverSweepsOtherFiles()
    {
        string directory = Path.Combine(Path.GetTempPath(), "maaso-retired-cache-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            byte[] bytes = { 1, 2, 3, 4 };
            string digest;
            using (var hash = SHA256.Create()) digest = string.Concat(hash.ComputeHash(bytes).Select(value => value.ToString("x2")));
            string target = Path.Combine(directory, digest + ".bundle");
            string unrelated = Path.Combine(directory, new string('a', 64) + ".bundle");
            File.WriteAllBytes(target, bytes); File.WriteAllBytes(unrelated, bytes);
            Assert.That(Call("PurgeVerifiedCache", directory, new[] { digest, new string('a', 64), "../outside" }), Is.EqualTo(1));
            Assert.That(File.Exists(target), Is.False);
            Assert.That(File.Exists(unrelated), Is.True, "A filename alone does not prove retired content ownership.");
            Assert.That(Call("PurgeVerifiedCache", directory, new[] { digest }), Is.Zero);
        }
        finally { Directory.Delete(directory, true); }
    }
}
