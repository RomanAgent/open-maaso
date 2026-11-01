using System;
using System.IO;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;

public sealed class PersonalSpaceSceneContractTests
{
    private const string ScenePath = "Assets/MaasoWorld/Scenes/PersonalSpace.unity";
    private const string AssetRoot = "Assets/MaasoWorld/PersonalSpace/CoastalV2";
    private const string PreviewPath = "Assets/MaasoWorld/PersonalSpace/PersonalSpaceUnityPreview.png";
    private const float ClearRadius = 1.2f;

    [Test]
    public void CurrentRoomKeepsStableGroundAndAgentStandingZoneClear()
    {
        WithPersonalSpace((sceneRoot, environment, model) =>
        {
            Assert.That(model.localPosition, Is.EqualTo(Vector3.zero));
            Assert.That(model.localScale, Is.EqualTo(Vector3.one));
            Assert.That(Quaternion.Angle(model.localRotation, Quaternion.identity), Is.LessThan(.01f));
            Collider[] colliders = environment.GetComponentsInChildren<Collider>(true);
            Assert.That(colliders, Has.Length.EqualTo(1));
            Assert.That(colliders[0], Is.TypeOf<BoxCollider>());
            Physics.SyncTransforms();
            Bounds ground = colliders[0].bounds;
            Assert.That(ground.size.x, Is.EqualTo(8f).Within(.01f));
            Assert.That(ground.size.z, Is.EqualTo(8f).Within(.01f));
            Assert.That(ground.max.y, Is.EqualTo(0f).Within(.001f));
            foreach (Vector2 point in new[] { Vector2.zero, new Vector2(-3.5f, -3.5f),
                         new Vector2(-3.5f, 3.5f), new Vector2(3.5f, -3.5f), new Vector2(3.5f, 3.5f) })
            {
                Assert.That(colliders[0].Raycast(new Ray(new Vector3(point.x, 5f, point.y), Vector3.down),
                    out RaycastHit hit, 10f), Is.True);
                Assert.That(hit.point.y, Is.EqualTo(0f).Within(.01f));
            }
            Renderer[] renderers = model.GetComponentsInChildren<Renderer>(true);
            Assert.That(renderers.Length, Is.GreaterThanOrEqualTo(12));
            Assert.That(environment.GetComponentsInChildren<Camera>(true), Is.Empty);
            Assert.That(environment.GetComponentsInChildren<AudioListener>(true), Is.Empty);
            Renderer floor = RendererNamed(model, "V2_Floor_Baked");
            Assert.That(floor.bounds.min.x, Is.EqualTo(-4f).Within(.012f));
            Assert.That(floor.bounds.max.x, Is.EqualTo(4f).Within(.012f));
            Assert.That(floor.bounds.min.z, Is.EqualTo(-4f).Within(.012f));
            Assert.That(floor.bounds.max.z, Is.EqualTo(4f).Within(.012f));
            Assert.That(floor.bounds.max.y, Is.EqualTo(0f).Within(.012f));
            Assert.That(RendererNamed(model, "V2_West_Wall").bounds.min.x, Is.EqualTo(4f).Within(.012f));
            Assert.That(RendererNamed(model, "V2_East_Wall").bounds.max.x, Is.EqualTo(-4f).Within(.012f));
            Assert.That(RendererNamed(model, "V2_Ceiling").bounds.min.y, Is.EqualTo(3.2f).Within(.012f));
            foreach (Renderer renderer in renderers)
            {
                if (renderer.bounds.max.y <= .08f || renderer.bounds.min.y >= 2.6f) continue;
                Bounds item = renderer.bounds;
                if (new Vector2(Mathf.Clamp(0f, item.min.x, item.max.x),
                    Mathf.Clamp(0f, item.min.z, item.max.z)).magnitude < ClearRadius)
                    AssertStandingZoneClearOfMesh(renderer);
            }
        });
    }

    [Test]
    public void RoomIncludesWindowCurtainsAndAnAuthoredExteriorView()
    {
        WithPersonalSpace((_, _, model) =>
        {
            Renderer[] profiles = model.GetComponentsInChildren<Renderer>(true)
                .Where(item => item.name.StartsWith("V2_Window_", StringComparison.Ordinal)).ToArray();
            Assert.That(profiles, Is.Not.Empty);
            Bounds opening = CombinedBounds(profiles);
            Assert.That(opening.size.x, Is.GreaterThan(7.8f));
            Assert.That(opening.center.z, Is.LessThan(-3.8f));
            foreach (string name in new[] { "V2_Sheer_Curtain_West", "V2_Sheer_Curtain_East",
                         "V2_Linen_Drape_West", "V2_Linen_Drape_East" })
                Assert.That(RendererNamed(model, name).bounds.size.y, Is.GreaterThan(2.8f));
            AssertCoastalView(RendererNamed(model, "V2_Distant_Ocean"));
            Assert.That(model.GetComponentsInChildren<Transform>(true).Any(item =>
                item.name.StartsWith("PS_", StringComparison.Ordinal)), Is.False);
        });
    }

    [TestCase("PersonalSpaceModel")]
    [TestCase("PersonalSpaceMap")]
    public void ShippedRoomResourcesKeepPhotographicViewAndSurfaceTextures(string resourceName)
    {
        GameObject resource = Resources.Load<GameObject>(resourceName);
        Assert.That(resource, Is.Not.Null, resourceName);
        AssertCoastalView(RendererNamed(resource.transform, "V2_Distant_Ocean"));
        foreach (Renderer renderer in AuthoredRoomRenderers(resource, resourceName))
        {
            Assert.That(renderer.sharedMaterials, Has.Length.EqualTo(1), renderer.name);
            Material material = renderer.sharedMaterial;
            Assert.That(material, Is.Not.Null);
            Assert.That(material.name, Does.StartWith("Baked_"));
            Assert.That(AssetDatabase.GetAssetPath(material), Does.StartWith(AssetRoot + "/Materials/"));
            Assert.That(AssetDatabase.GetAssetPath(material.mainTexture), Does.StartWith(AssetRoot + "/Baked_"));
            AssertWarmMatteMaterial(material);
            AssertUsableTextureCoordinates(renderer);
        }
    }

    [TestCase("Baked_Floor.png", false)]
    [TestCase("Baked_Sofa.png", false)]
    [TestCase("Baked_Ocean.png", false)]
    [TestCase("Baked_Sheer.png", true)]
    public void BundledRoomTexturesKeepMobileMemoryAndColourContracts(string fileName, bool transparent)
    {
        var importer = AssetImporter.GetAtPath(AssetRoot + "/" + fileName) as TextureImporter;
        Assert.That(importer, Is.Not.Null);
        Assert.That(importer.sRGBTexture, Is.True, "Blender save_render already applied the display transform.");
        Assert.That(importer.isReadable, Is.False);
        Assert.That(importer.mipmapEnabled, Is.True);
        Assert.That(importer.wrapMode, Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(importer.anisoLevel, Is.GreaterThanOrEqualTo(4));
        Assert.That(importer.alphaSource, Is.EqualTo(transparent ?
            TextureImporterAlphaSource.FromInput : TextureImporterAlphaSource.None));
        Assert.That(importer.maxTextureSize, Is.EqualTo(4096));
        foreach (string platform in new[] { "iPhone", "Android" })
        {
            TextureImporterPlatformSettings settings = importer.GetPlatformTextureSettings(platform);
            Assert.That(settings.overridden, Is.True);
            Assert.That(settings.maxTextureSize, Is.EqualTo(4096));
            Assert.That(settings.format, Is.EqualTo(TextureImporterFormat.ASTC_4x4));
        }
    }

    [TestCase("PersonalSpaceModel")]
    [TestCase("PersonalSpaceMap")]
    public void InteriorLightsOnlyIlluminateRoomGeometryWithoutChangingAvatarLighting(string resourceName)
    {
        GameObject resource = Resources.Load<GameObject>(resourceName);
        Assert.That(resource, Is.Not.Null);
        int roomLayer = LayerMask.NameToLayer("PersonalSpaceEnvironment");
        Assert.That(roomLayer, Is.GreaterThanOrEqualTo(0));
        Assert.That(resource.GetComponentsInChildren<Light>(true), Is.Empty,
            "Baked radiance must not introduce a second room light or change avatar lighting.");
        foreach (Renderer renderer in AuthoredRoomRenderers(resource, resourceName))
        {
            Assert.That(renderer.gameObject.layer, Is.EqualTo(roomLayer));
            Assert.That(renderer.receiveShadows, Is.False);
            Assert.That(renderer.shadowCastingMode, Is.EqualTo(ShadowCastingMode.Off));
            Assert.That(renderer.lightProbeUsage, Is.EqualTo(LightProbeUsage.Off));
            Assert.That(renderer.reflectionProbeUsage, Is.EqualTo(ReflectionProbeUsage.Off));
        }
    }

    [Test]
    public void FurnitureRetainsTheConceptDetailsAndSoftMatteMaterial()
    {
        WithPersonalSpace((_, _, model) =>
        {
            string[] names = model.GetComponentsInChildren<Transform>(true).Select(item => item.name).ToArray();
            Assert.That(names.Any(name => name.IndexOf("bed", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.Contains("PREVIEW_ONLY") || name.Contains("Mannequin")), Is.False);
            foreach (string name in new[] { "V2_Sofa_Baked", "V2_WorkDesk_Baked", "V2_Bookshelf_Baked",
                         "V2_Sideboard_Baked", "V2_Olive_Baked", "V2_Strelitzia_Baked", "V2_CoffeeTable_Baked" })
                Assert.That(RendererNamed(model, name).GetComponent<MeshFilter>().sharedMesh.vertexCount, Is.GreaterThan(8));
            Material[] materials = model.GetComponentsInChildren<Renderer>(true)
                .SelectMany(item => item.sharedMaterials).Distinct().ToArray();
            Assert.That(materials.Length, Is.GreaterThanOrEqualTo(12));
            Assert.That(materials.Select(item => item.mainTexture).Distinct().Count(), Is.EqualTo(materials.Length));
            foreach (Material material in materials) AssertWarmMatteMaterial(material);
        });
    }

    [Test]
    public void UnityPreviewKeepsHighlightsAndContactShadowsInsteadOfClippingWhite()
    {
        Assert.That(File.Exists(PreviewPath), Is.True, PreviewPath);
        var image = new Texture2D(2, 2, TextureFormat.RGB24, false);
        try
        {
            Assert.That(image.LoadImage(File.ReadAllBytes(PreviewPath)), Is.True);
            Assert.That(image.width, Is.EqualTo(1600));
            Assert.That(image.height, Is.EqualTo(900));
            Color[] pixels = image.GetPixels();
            Assert.That(pixels.Max(pixel => pixel.grayscale) - pixels.Min(pixel => pixel.grayscale), Is.GreaterThan(.5f));
            Assert.That(pixels.Count(pixel => pixel.r > .995f && pixel.g > .995f && pixel.b > .995f) /
                (float)pixels.Length, Is.LessThan(.15f), "A washed-out or missing-material frame must fail.");
            Color floor = MeanFloorColor(image);
            Assert.That(floor.r, Is.GreaterThan(floor.b + .025f), "The actual floor pixels should retain warm oak.");
        }
        finally { UnityEngine.Object.DestroyImmediate(image); }
    }

    private static void AssertCoastalView(Renderer renderer)
    {
        Assert.That(renderer.bounds.center.z, Is.LessThan(-4f));
        AssertWarmMatteMaterial(renderer.sharedMaterial);
        Assert.That(renderer.sharedMaterial.GetFloat("_Mode"), Is.Zero);
        Assert.That(renderer.sharedMaterial.GetInt("_ZWrite"), Is.EqualTo(1));
        Assert.That(AssetDatabase.GetAssetPath(renderer.sharedMaterial.mainTexture), Is.EqualTo(AssetRoot + "/Baked_Ocean.png"));
        Assert.That(renderer.shadowCastingMode, Is.EqualTo(ShadowCastingMode.Off));
        AssertUsableTextureCoordinates(renderer);
    }

    private static void AssertUsableTextureCoordinates(Renderer renderer)
    {
        Mesh mesh = renderer.GetComponent<MeshFilter>()?.sharedMesh;
        Assert.That(mesh, Is.Not.Null, renderer.name);
        Vector2[] uv = mesh.uv;
        Assert.That(uv.Length, Is.EqualTo(mesh.vertexCount));
        Assert.That(uv.Length, Is.GreaterThan(0));
        Assert.That(uv.All(value => !float.IsNaN(value.x) && !float.IsInfinity(value.x) &&
            !float.IsNaN(value.y) && !float.IsInfinity(value.y)), Is.True);
        float area = 0f;
        int[] triangles = mesh.triangles;
        for (int i = 0; i < triangles.Length; i += 3)
        {
            Vector2 a = uv[triangles[i + 1]] - uv[triangles[i]];
            Vector2 b = uv[triangles[i + 2]] - uv[triangles[i]];
            area += Mathf.Abs(a.x * b.y - a.y * b.x) * .5f;
        }
        Assert.That(area, Is.GreaterThan(.000001f), renderer.name + " must not collapse to a single atlas texel.");
    }

    private static Renderer[] AuthoredRoomRenderers(GameObject resource, string resourceName)
    {
        Transform model = resourceName == "PersonalSpaceModel" ? resource.transform :
            resource.GetComponentsInChildren<Transform>(true).Single(value => value.name == "PersonalSpaceModel");
        Renderer[] authoredRenderers = model.GetComponentsInChildren<Renderer>(true);
        Assert.That(authoredRenderers, Is.Not.Empty);
        Renderer[] fallbackRenderers = resource.GetComponentsInChildren<Renderer>(true).Except(authoredRenderers).ToArray();
        Assert.That(fallbackRenderers.Length, Is.EqualTo(resourceName == "PersonalSpaceMap" ? 1 : 0));
        foreach (Renderer fallback in fallbackRenderers)
        {
            Assert.That(fallback.name, Is.EqualTo("WorldGround"),
                "Only the runtime walking-ground fallback may exist outside the room model.");
            var collider = fallback.GetComponent<BoxCollider>();
            Assert.That(collider, Is.Not.Null);
            Vector3 size = Vector3.Scale(collider.size, collider.transform.lossyScale);
            Assert.That(size.x, Is.EqualTo(8f).Within(.001f));
            Assert.That(size.z, Is.EqualTo(8f).Within(.001f));
        }
        return authoredRenderers;
    }

    private static void AssertWarmMatteMaterial(Material material)
    {
        Assert.That(material.shader.name, Is.EqualTo("Maaso/CoastalBakedRadiance"));
        Assert.That(material.color.r, Is.Zero); Assert.That(material.color.g, Is.Zero); Assert.That(material.color.b, Is.Zero);
        Assert.That(material.GetTexture("_EmissionMap"), Is.SameAs(material.mainTexture));
        Assert.That(material.GetColor("_EmissionColor"), Is.EqualTo(Color.white));
        Assert.That(material.mainTexture, Is.Not.Null);
        Assert.That(material.passCount, Is.EqualTo(2));
        Assert.That(material.FindPass("ShadowCaster"), Is.GreaterThanOrEqualTo(0));
        Assert.That(material.GetFloat("_GlossyReflections"), Is.Zero);
        Assert.That(material.GetFloat("_SpecularHighlights"), Is.Zero);
        Assert.That(material.globalIlluminationFlags, Is.EqualTo(MaterialGlobalIlluminationFlags.None));
        if (material.name == "Baked_Sheer")
        {
            Assert.That(material.GetFloat("_Mode"), Is.EqualTo(2));
            Assert.That(material.color.a, Is.EqualTo(.38f).Within(.001f));
            Assert.That(material.GetInt("_ZWrite"), Is.Zero);
        }
        else Assert.That(material.GetFloat("_Mode"), Is.Zero);
    }

    private static Color MeanFloorColor(Texture2D texture)
    {
        Color[] pixels = texture.GetPixels(texture.width / 4, texture.height / 16, texture.width / 2, texture.height / 8);
        Color sum = Color.black;
        foreach (Color pixel in pixels) sum += pixel;
        return sum / pixels.Length;
    }

    private static void WithPersonalSpace(
        Action<GameObject, Transform, Transform> assertion)
    {
        Scene scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Additive);
        try
        {
            GameObject sceneRoot = scene
                .GetRootGameObjects()
                .Single(value => value.name == "PersonalSpaceSceneRoot");
            Transform environment = sceneRoot.transform.Find(
                "PersonalSpaceEnvironment");
            Assert.That(environment, Is.Not.Null);
            Transform model = environment.Find("PersonalSpaceModel");
            Assert.That(model, Is.Not.Null);
            assertion(sceneRoot, environment, model);
        }
        finally
        {
            EditorSceneManager.CloseScene(scene, true);
        }
    }

    private static Renderer RendererNamed(Transform model, string name)
    {
        Renderer renderer = model
            .GetComponentsInChildren<Renderer>(true)
            .SingleOrDefault(value => value.name == name);
        Assert.That(renderer, Is.Not.Null, name);
        return renderer;
    }

    private static void AssertStandingZoneClearOfMesh(Renderer renderer)
    {
        Mesh mesh = renderer.GetComponent<MeshFilter>()?.sharedMesh;
        Assert.That(mesh, Is.Not.Null, renderer.name);
        Vector3[] vertices = mesh.vertices;
        int[] triangles = mesh.triangles;
        for (int index = 0; index < vertices.Length; index++)
        {
            vertices[index] = renderer.transform.TransformPoint(vertices[index]);
        }
        for (int index = 0; index < triangles.Length; index += 3)
        {
            Vector3 a = vertices[triangles[index]];
            Vector3 b = vertices[triangles[index + 1]];
            Vector3 c = vertices[triangles[index + 2]];
            if (Mathf.Max(a.y, b.y, c.y) <= 0.08f ||
                Mathf.Min(a.y, b.y, c.y) >= 2.6f)
            {
                continue;
            }
            // Combined wall trim can surround an empty center inside one large
            // renderer bounds. Test its real triangles, not that empty box.
            float distance = DistanceToProjectedTriangle(
                new Vector2(a.x, a.z), new Vector2(b.x, b.z), new Vector2(c.x, c.z));
            Assert.That(distance, Is.GreaterThanOrEqualTo(ClearRadius),
                $"{renderer.name} triangle {index / 3} enters the Agent's standing zone " +
                $"at {distance:0.000}m.");
        }
    }

    private static float DistanceToProjectedTriangle(Vector2 a, Vector2 b, Vector2 c)
    {
        float Cross(Vector2 left, Vector2 right) => left.x * right.y - left.y * right.x;
        float ab = Cross(b - a, -a);
        float bc = Cross(c - b, -b);
        float ca = Cross(a - c, -c);
        if (Mathf.Abs(Cross(b - a, c - a)) > 0.000001f &&
            (ab >= 0f && bc >= 0f && ca >= 0f || ab <= 0f && bc <= 0f && ca <= 0f))
        {
            return 0f;
        }
        float SegmentDistance(Vector2 start, Vector2 end)
        {
            Vector2 delta = end - start;
            float amount = delta.sqrMagnitude > 0f
                ? Mathf.Clamp01(-Vector2.Dot(start, delta) / delta.sqrMagnitude) : 0f;
            return (start + delta * amount).magnitude;
        }
        return Mathf.Min(SegmentDistance(a, b), SegmentDistance(b, c), SegmentDistance(c, a));
    }

    private static Bounds CombinedBounds(Renderer[] renderers)
    {
        Bounds bounds = renderers[0].bounds;
        for (int index = 1; index < renderers.Length; index++)
        {
            bounds.Encapsulate(renderers[index].bounds);
        }
        return bounds;
    }
}
