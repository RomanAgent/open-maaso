using System;
using System.Collections.Generic;
using System.Reflection;
using NUnit.Framework;
using Unity.Collections;
using UnityEditor;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class AvatarSkinningQualityTests
{
    private const string ReceiverType =
        "Maaso.Avatar.UnityAvatarCommandReceiver, Assembly-CSharp";

    [Test]
    public void MobileMediumKeepsFourWeightsOnlyInsideAvatarIncludingInactiveMeshes()
    {
        using var fixture = new Fixture();
        var avatar = fixture.Root("Avatar");
        var clothing = fixture.Renderer(avatar, "InactiveClothing", 4);
        clothing.gameObject.SetActive(false);
        var world = fixture.Root("World");
        var unrelated = fixture.Renderer(world, "WorldMesh", 4);
        int previousLevel = QualitySettings.GetQualityLevel();
        try
        {
            int medium = Array.IndexOf(QualitySettings.names, "Medium");
            Assert.That(medium, Is.GreaterThanOrEqualTo(0));
            QualitySettings.SetQualityLevel(medium, false);
            Assert.That(QualitySettings.skinWeights, Is.EqualTo(SkinWeights.TwoBones));
            float shadowDistance = QualitySettings.shadowDistance;
            int mipLimit = QualitySettings.globalTextureMipmapLimit;
            int antiAliasing = QualitySettings.antiAliasing;

            Apply(avatar.transform);

            Assert.That(clothing.quality, Is.EqualTo(SkinQuality.Bone4));
            Assert.That(unrelated.quality, Is.EqualTo(SkinQuality.Auto));
            Assert.That(QualitySettings.GetQualityLevel(), Is.EqualTo(medium));
            Assert.That(QualitySettings.skinWeights, Is.EqualTo(SkinWeights.TwoBones));
            Assert.That(QualitySettings.shadowDistance, Is.EqualTo(shadowDistance));
            Assert.That(QualitySettings.globalTextureMipmapLimit, Is.EqualTo(mipLimit));
            Assert.That(QualitySettings.antiAliasing, Is.EqualTo(antiAliasing));
        }
        finally
        {
            QualitySettings.SetQualityLevel(previousLevel, false);
        }
    }

    [Test]
    public void UploadedMeshStillReceivesFourBonePolicyWithoutRequiringCpuReadability()
    {
        using var fixture = new Fixture();
        var avatar = fixture.Root("UploadedAvatar");
        var renderer = fixture.Renderer(avatar, "UploadedClothing", 4);
        renderer.sharedMesh.UploadMeshData(true);
        Assert.That(renderer.sharedMesh.isReadable, Is.False);

        Apply(avatar.transform);

        Assert.That(renderer.quality, Is.EqualTo(SkinQuality.Bone4));
        Assert.That(renderer.sharedMesh.isReadable, Is.False);
    }

    [Test]
    public void NullAndUnweightedRenderersAreNotChanged()
    {
        using var fixture = new Fixture();
        var root = fixture.Root("UnweightedAvatar");
        var renderer = root.AddComponent<SkinnedMeshRenderer>();
        Apply(null);
        Apply(root.transform);
        Assert.That(renderer.quality, Is.EqualTo(SkinQuality.Auto));
    }

    [Test]
    public void ActualJoyPrefabRetainsEveryAuthoredInfluenceOnMobileMedium()
    {
        using var quality = new MobileMediumQuality();
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
            "Assets/MaasoAvatar/Models/Default/Joy.vrm");
        Assert.That(prefab, Is.Not.Null);
        GameObject avatar = Object.Instantiate(prefab);
        try
        {
            Apply(avatar.transform);
            int fourWeightMeshCount = 0;
            foreach (SkinnedMeshRenderer renderer in
                avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true))
            {
                Mesh mesh = renderer.sharedMesh;
                if (mesh == null) continue;
                var counts = mesh.GetBonesPerVertex();
                int maximum = 0;
                for (int vertex = 0; vertex < counts.Length; vertex++)
                    maximum = Math.Max(maximum, counts[vertex]);
                if (maximum == 0) continue;
                Assert.That(maximum, Is.LessThanOrEqualTo(4),
                    "The bundled VRM asset must stay within the reviewed four-weight contract: " + mesh.name);
                Assert.That(renderer.quality, Is.EqualTo(SkinQuality.Bone4),
                    mesh.name + " imported buffer layout: " + mesh.skinWeightBufferLayout);
                if (maximum > 2) fourWeightMeshCount++;
            }
            Assert.That(fourWeightMeshCount, Is.GreaterThan(0),
                "Validate an actual multi-weight avatar, not an empty import.");
            Assert.That(QualitySettings.skinWeights, Is.EqualTo(SkinWeights.TwoBones));
        }
        finally
        {
            Object.DestroyImmediate(avatar);
        }
    }

    [TestCase(SkinQuality.Auto)]
    [TestCase(SkinQuality.Bone2)]
    public void CustomMeshesAboveFourWeightsRetainTheirExistingPolicy(SkinQuality quality)
    {
        using var fixture = new Fixture();
        var avatar = fixture.Root("CustomAvatar");
        var renderer = fixture.Renderer(avatar, "FiveWeightMesh", 5);
        renderer.quality = quality;
        Assert.That(renderer.sharedMesh.skinWeightBufferLayout, Is.EqualTo(SkinWeights.Unlimited));

        Apply(avatar.transform);

        Assert.That(renderer.quality, Is.EqualTo(quality),
            "Do not cap a custom Auto/Unlimited mesh to four weights.");
        Assert.That(renderer.sharedMesh.GetBonesPerVertex()[0], Is.EqualTo(5));
    }

    [Test]
    public void BundledAwakeAndDynamicActivationUseTheSameSkinningPolicy()
    {
        using var fixture = new Fixture();
        var bundled = fixture.Root("BundledAvatar");
        var bundledRenderer = fixture.Renderer(bundled, "BundledClothing", 4);
        Component receiver = fixture.Receiver(bundled.transform);
        Invoke(receiver, "Awake");
        Assert.That(bundledRenderer.quality, Is.EqualTo(SkinQuality.Bone4));
        var replacement = fixture.Root("RuntimeVrmReplacement");
        var replacementRenderer = fixture.Renderer(replacement, "RuntimeClothing", 4);

        // This is the activation boundary after the asynchronous VRM importer
        // has returned; the test needs no network, file download or VRM runtime.
        Invoke(receiver, "ActivateLoadedAvatarReplacement", replacement, null,
            null, bundled.transform, "skinning test");

        Assert.That(replacementRenderer.quality, Is.EqualTo(SkinQuality.Bone4));
        Assert.That(receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(receiver),
            Is.SameAs(replacement.transform));
        Assert.That(bundled.activeSelf, Is.False);
    }

    [Test]
    public void WorldLeaseWalkIdleAndBundledFallbackDoNotResetSkinningPolicy()
    {
        using var quality = new MobileMediumQuality();
        using var fixture = new Fixture();
        var bundled = fixture.Root("BundledAvatar");
        var bundledRenderer = fixture.Renderer(bundled, "BundledClothing", 4);
        Component receiver = fixture.Receiver(bundled.transform);
        Invoke(receiver, "Awake");
        var replacement = fixture.Root("ReplacementAvatar");
        var replacementRenderer = fixture.Renderer(replacement, "ReplacementClothing", 4);
        Invoke(receiver, "BindAvatarRoot", replacement.transform);
        var worldParent = fixture.Root("WorldOwner");

        Assert.That(Invoke(receiver, "TryLeaseActiveAvatarForWorld", worldParent.transform), Is.True);
        Assert.That(replacement.transform.parent, Is.SameAs(worldParent.transform));
        Invoke(receiver, "SetWorldLocomotion", true);
        Assert.That(replacementRenderer.quality, Is.EqualTo(SkinQuality.Bone4));
        Invoke(receiver, "SetWorldLocomotion", false);
        Invoke(receiver, "RestoreActiveAvatarFromWorld", new object[] { null });
        Assert.That(replacement.transform.parent, Is.Null);
        Assert.That(replacementRenderer.quality, Is.EqualTo(SkinQuality.Bone4));

        // Bind a different active model, then exercise the bundled fallback path.
        // No reviewed bundle is owned by this fixture, so no deferred Destroy is needed.
        Assert.That(Invoke(receiver, "RestoreBundledAvatar"), Is.True);
        Assert.That(bundledRenderer.quality, Is.EqualTo(SkinQuality.Bone4));
        Assert.That(receiver.GetType().GetProperty("ActiveAvatarRoot").GetValue(receiver),
            Is.SameAs(bundled.transform));

        Assert.That(QualitySettings.skinWeights, Is.EqualTo(SkinWeights.TwoBones));
    }

    private static void Apply(Transform root) =>
        Type.GetType("Maaso.Avatar.AvatarSkinningQuality, Maaso.VrmBridge", true)
            .GetMethod("Apply").Invoke(null, new object[] { root });

    private static object Invoke(Component receiver, string method, params object[] args) =>
        receiver.GetType().GetMethod(method,
            BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)
            .Invoke(receiver, args);

    private sealed class MobileMediumQuality : IDisposable
    {
        private readonly int previousLevel = QualitySettings.GetQualityLevel();

        public MobileMediumQuality()
        {
            int medium = Array.IndexOf(QualitySettings.names, "Medium");
            Assert.That(medium, Is.GreaterThanOrEqualTo(0));
            QualitySettings.SetQualityLevel(medium, false);
            Assert.That(QualitySettings.skinWeights, Is.EqualTo(SkinWeights.TwoBones));
        }

        public void Dispose() => QualitySettings.SetQualityLevel(previousLevel, false);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly List<GameObject> roots = new();
        private readonly List<Mesh> meshes = new();

        public GameObject Root(string name)
        {
            var root = new GameObject(name);
            roots.Add(root);
            return root;
        }

        public Component Receiver(Transform avatarRoot)
        {
            Component receiver = Root("ReceiverHost").AddComponent(Type.GetType(ReceiverType, true));
            receiver.GetType().GetField("avatarRoot", BindingFlags.NonPublic | BindingFlags.Instance)
                .SetValue(receiver, avatarRoot);
            return receiver;
        }

        public SkinnedMeshRenderer Renderer(GameObject root, string name, byte influences)
        {
            var mesh = new Mesh
            {
                name = name,
                vertices = new[] { Vector3.zero, Vector3.right, Vector3.up },
                triangles = new[] { 0, 1, 2 },
            };
            meshes.Add(mesh);
            var bindposes = new Matrix4x4[influences];
            var bones = new Transform[influences];
            for (int bone = 0; bone < influences; bone++)
            {
                bones[bone] = new GameObject("Bone" + bone).transform;
                bones[bone].SetParent(root.transform, false);
                bindposes[bone] = Matrix4x4.identity;
            }
            mesh.bindposes = bindposes;
            var values = new BoneWeight1[3 * influences];
            for (int vertex = 0; vertex < 3; vertex++)
            for (int bone = 0; bone < influences; bone++)
                values[vertex * influences + bone] = new BoneWeight1
                {
                    boneIndex = bone,
                    weight = 1f / influences,
                };
            using var counts = new NativeArray<byte>(new[] { influences, influences, influences }, Allocator.Temp);
            using var weights = new NativeArray<BoneWeight1>(values, Allocator.Temp);
            mesh.SetBoneWeights(counts, weights);
            var child = new GameObject(name);
            child.transform.SetParent(root.transform, false);
            var renderer = child.AddComponent<SkinnedMeshRenderer>();
            renderer.sharedMesh = mesh;
            renderer.bones = bones;
            renderer.rootBone = bones[0];
            renderer.quality = SkinQuality.Auto;
            return renderer;
        }

        public void Dispose()
        {
            for (int i = roots.Count - 1; i >= 0; i--)
                if (roots[i] != null) Object.DestroyImmediate(roots[i]);
            foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
        }
    }
}
