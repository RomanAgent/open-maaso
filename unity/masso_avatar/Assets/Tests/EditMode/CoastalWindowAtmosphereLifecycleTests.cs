using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using Object = UnityEngine.Object;

public sealed class CoastalWindowAtmosphereLifecycleTests
{
    private static Type Atmosphere => Type.GetType("Maaso.World.CoastalWindowAtmosphere, Assembly-CSharp", true);

    [Test]
    public void MissingAssetsAndNonFiniteTimeDoNotCreateOrMoveVolumes()
    {
        using var fixture = new Fixture();
        fixture.PresentAt(0);
        Assert.That(fixture.Root.transform.childCount, Is.Zero);
        fixture.Configure();
        foreach (float time in new[] { float.NaN, float.PositiveInfinity, float.NegativeInfinity })
            fixture.PresentAt(time);
        Assert.That(fixture.Root.transform.childCount, Is.Zero);
        fixture.PresentAt(20);
        var before = fixture.Renderers.Select(renderer => renderer.transform.localPosition).ToArray();
        foreach (float time in new[] { float.NaN, float.PositiveInfinity, float.NegativeInfinity })
            fixture.PresentAt(time);
        CollectionAssert.AreEqual(before, fixture.Renderers.Select(renderer => renderer.transform.localPosition).ToArray());
    }

    [Test]
    public void PresentationReusesInstancesAndKeepsStaticDensityVariants()
    {
        using var fixture = new Fixture();
        fixture.Configure();
        fixture.PresentAt(0);
        var renderers = fixture.Renderers;
        Assert.That(renderers.Length, Is.EqualTo(6));
        var properties = new MaterialPropertyBlock();
        var variants = new float[renderers.Length];
        for (int i = 0; i < renderers.Length; i++)
        {
            renderers[i].GetPropertyBlock(properties);
            variants[i] = properties.GetFloat("_CloudVariant");
            Assert.That(variants[i], Is.EqualTo(i % 2));
            Assert.That(properties.GetFloat("_DensityMultiplier"), Is.InRange(.85f, 1.05f));
            Assert.That(renderers[i].transform.localRotation, Is.EqualTo(Quaternion.identity));
            Assert.That(renderers[i].transform.localScale.x, Is.GreaterThan(0));
            Assert.That(renderers[i].transform.localScale.y, Is.GreaterThan(0));
            Assert.That(renderers[i].transform.localScale.z, Is.GreaterThan(0));
        }
        fixture.Configure(); // An identical configuration must not recreate the volumes.
        for (int frame = 0; frame < 120; frame++) fixture.PresentAt(frame / 60f);
        var after = fixture.Renderers;
        Assert.That(after.Length, Is.EqualTo(renderers.Length));
        for (int i = 0; i < renderers.Length; i++)
        {
            Assert.That(after[i], Is.SameAs(renderers[i]));
            renderers[i].GetPropertyBlock(properties);
            Assert.That(properties.GetFloat("_CloudVariant"), Is.EqualTo(variants[i]));
            Assert.That(renderers[i].sharedMaterial, Is.SameAs(fixture.Material));
            Assert.That(renderers[i].GetComponent<MeshFilter>().sharedMesh, Is.SameAs(fixture.Mesh));
        }
    }

    [Test]
    public void SourceReplacementAndRemovalClearInstancesWithoutDestroyingSharedAssets()
    {
        using var fixture = new Fixture();
        var replacementMesh = Object.Instantiate(fixture.Mesh);
        var replacementMaterial = new Material(fixture.Material);
        try
        {
            fixture.Configure();
            fixture.PresentAt(0);
            var old = fixture.Renderers;
            fixture.Configure(replacementMesh, replacementMaterial);
            Assert.That(fixture.Root.transform.childCount, Is.Zero);
            Assert.That(old.All(renderer => renderer == null), Is.True);
            fixture.PresentAt(10);
            Assert.That(fixture.Renderers.Length, Is.EqualTo(6));
            foreach (var renderer in fixture.Renderers)
            {
                Assert.That(renderer.sharedMaterial, Is.SameAs(replacementMaterial));
                Assert.That(renderer.GetComponent<MeshFilter>().sharedMesh, Is.SameAs(replacementMesh));
            }
            fixture.Configure(null, null);
            fixture.PresentAt(11);
            Assert.That(fixture.Root.transform.childCount, Is.Zero);
            Assert.That(fixture.Mesh != null && fixture.Material != null, Is.True);
            Assert.That(replacementMesh != null && replacementMaterial != null, Is.True);
        }
        finally
        {
            Object.DestroyImmediate(replacementMaterial);
            Object.DestroyImmediate(replacementMesh);
        }
    }

    [Test]
    public void DisabledComponentCannotRecreateCloudsAndReenableCreatesOneSet()
    {
        using var fixture = new Fixture();
        fixture.Configure();
        fixture.PresentAt(0);
        fixture.Component.enabled = false;
        fixture.InvokeLifecycle("OnDisable");
        fixture.PresentAt(100);
        Assert.That(fixture.Root.transform.childCount, Is.Zero);
        fixture.Component.enabled = true;
        fixture.PresentAt(100);
        Assert.That(fixture.Root.transform.childCount, Is.EqualTo(1));
        Assert.That(fixture.Renderers.Length, Is.EqualTo(6));
        fixture.Root.SetActive(false);
        fixture.InvokeLifecycle("OnDisable");
        fixture.PresentAt(200);
        Assert.That(fixture.Root.transform.childCount, Is.Zero);
        fixture.Root.SetActive(true);
        fixture.PresentAt(200);
        Assert.That(fixture.Root.transform.childCount, Is.EqualTo(1));
        Assert.That(fixture.Renderers.Length, Is.EqualTo(6));
    }

    [Test]
    public void DestroyedAtmosphereReleasesInstancesAndRetainsSharedSources()
    {
        using var fixture = new Fixture();
        fixture.Configure();
        fixture.PresentAt(0);
        var renderers = fixture.Renderers;
        // Runtime-only MonoBehaviours do not dispatch all callbacks in EditMode.
        fixture.InvokeLifecycle("OnDestroy");
        fixture.InvokeLifecycle("OnDestroy");
        Assert.That(fixture.Root.transform.childCount, Is.Zero);
        Assert.That(renderers.All(renderer => renderer == null), Is.True);
        Assert.That(fixture.Mesh != null && fixture.Material != null, Is.True);
    }

    private sealed class Fixture : IDisposable
    {
        public readonly GameObject Root = new("atmosphere-lifecycle-fixture");
        public readonly Mesh Mesh;
        public readonly Material Material;
        public readonly Behaviour Component;
        public MeshRenderer[] Renderers => Root.GetComponentsInChildren<MeshRenderer>();

        public Fixture()
        {
            var builder = Type.GetType("Maaso.World.Editor.CoastalCloudMeshBuilder, Assembly-CSharp-Editor", true);
            Mesh = (Mesh)builder.GetMethod("BuildMesh").Invoke(null, null);
            Material = new Material(Shader.Find("Maaso/Coastal Cloud Volume"));
            Component = (Behaviour)Root.AddComponent(Atmosphere);
        }

        public void Configure() => Configure(Mesh, Material);
        public void Configure(Mesh mesh, Material material) => Atmosphere.GetMethod("Configure").Invoke(Component, new object[] { mesh, material });
        public void PresentAt(float time) => Atmosphere.GetMethod("PresentAt").Invoke(Component, new object[] { time });
        public void InvokeLifecycle(string name) => Atmosphere.GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(Component, null);

        public void Dispose()
        {
            Object.DestroyImmediate(Root);
            Object.DestroyImmediate(Material);
            Object.DestroyImmediate(Mesh);
        }
    }
}
