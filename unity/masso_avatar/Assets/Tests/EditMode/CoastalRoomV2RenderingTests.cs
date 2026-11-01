using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

public sealed class CoastalRoomV2RenderingTests
{
    [TestCase(1f)]
    [TestCase(.38f)]
    public void ExplicitNightThemeDimsBakedRadianceAndRestoresDayPixels(float opacity)
    {
        using var fixture = new Fixture();
        float previousBlend = Shader.GetGlobalFloat("_MaasoWorldNightBlend");
        try
        {
            Renderer card = fixture.Surface("RoomNightTheme", new Vector3(0, 0, 3),
                new Vector3(10, 10, .1f));
            Material material = fixture.BakedMaterial(opacity);
            card.sharedMaterial = material;
            Shader.SetGlobalFloat("_MaasoWorldNightBlend", 0f);
            Color32[] day = fixture.Capture();

            Shader.SetGlobalFloat("_MaasoWorldNightBlend", .5f);
            Color32[] transition = fixture.Capture();
            Shader.SetGlobalFloat("_MaasoWorldNightBlend", 1f);
            Color32[] night = fixture.Capture();
            int center = day.Length / 2;
            Assert.That(night[center].r, Is.LessThan(day[center].r * .75f),
                "The room must visibly dim with the avatar when dark appearance is selected.");
            Assert.That(night[center].b, Is.GreaterThan(10),
                "Night must preserve the environment rather than replace it with black.");
            Assert.That(transition[center].r, Is.GreaterThan(night[center].r));
            Assert.That(transition[center].r, Is.LessThan(day[center].r));
            Assert.That(material.GetColor("_EmissionColor"), Is.EqualTo(Color.white),
                "Theme changes must not mutate imported radiance or per-instance cutaway materials.");
            Assert.That(material.GetColor("_Color").a, Is.EqualTo(opacity).Within(.001f));

            Shader.SetGlobalFloat("_MaasoWorldNightBlend", 0f);
            Assert.That(MaxPixelDifference(day, fixture.Capture()), Is.LessThanOrEqualTo(1),
                "Returning to daylight must restore the authored room pixels.");
        }
        finally
        {
            Shader.SetGlobalFloat("_MaasoWorldNightBlend", previousBlend);
        }
    }

    [TestCase(1f)]
    [TestCase(.38f)]
    public void BakedPixelsStayIdenticalThroughDayAndNightFog(float opacity)
    {
        using var fixture = new Fixture();
        Renderer card = fixture.Surface("OceanTest", new Vector3(0, 0, 45), new Vector3(100, 100, .1f));
        Material material = fixture.BakedMaterial(opacity);
        card.sharedMaterial = material;
        Shader shader = material.shader;
        Assert.That(shader.name, Is.EqualTo("Maaso/CoastalBakedRadiance"));
        Assert.That(shader.isSupported, Is.True);
        Assert.That(ShaderUtil.ShaderHasError(shader), Is.False);
        RenderSettings.fog = false;
        RenderSettings.ambientLight = Color.white;
        Color32[] day = fixture.Capture();
        RenderSettings.fog = true;
        RenderSettings.fogMode = FogMode.ExponentialSquared;
        RenderSettings.fogDensity = .012f;
        RenderSettings.fogColor = new Color(.025f, .055f, .13f);
        RenderSettings.ambientLight = Color.blue * .05f;
        Color32[] night = fixture.Capture();
        Assert.That(day[day.Length / 2].r, Is.GreaterThan(80), "Both frames must contain actual warm atlas pixels.");
        Assert.That(MaxPixelDifference(day, night), Is.LessThanOrEqualTo(1),
            "A day/night global change must not recolor display-referred room radiance, including sheer blending.");
        if (opacity == 1f)
        {
            Color32 center = day[day.Length / 2];
            Assert.That(center.r, Is.EqualTo(208).Within(3));
            Assert.That(center.g, Is.EqualTo(164).Within(3));
            Assert.That(center.b, Is.EqualTo(112).Within(3), "The sRGB atlas must not be gamma-decoded or encoded twice.");
            // Positive control proves that this camera really has active fog.
            Material standard = fixture.NewMaterial(Shader.Find("Standard"));
            standard.color = Color.black;
            standard.SetTexture("_EmissionMap", material.GetTexture("_EmissionMap"));
            standard.SetColor("_EmissionColor", Color.white);
            standard.EnableKeyword("_EMISSION");
            standard.EnableKeyword("_SPECULARHIGHLIGHTS_OFF");
            standard.EnableKeyword("_GLOSSYREFLECTIONS_OFF");
            card.sharedMaterial = standard;
            Color32[] foggedStandard = fixture.Capture();
            RenderSettings.fog = false;
            Color32[] clearStandard = fixture.Capture();
            Assert.That(MaxPixelDifference(clearStandard, foggedStandard), Is.GreaterThan(5),
                "The Standard control must demonstrate the night-fog regression this shader avoids.");
        }
    }

    [TestCase(1f)]
    [TestCase(.38f)]
    public void RuntimeCutawayPreservesBakedShaderAndRestoresTheOriginalMaterial(float opacity)
    {
        using var fixture = new Fixture();
        var mapRoot = new GameObject("CoastalCutawayMap");
        SceneManager.MoveGameObjectToScene(mapRoot, fixture.Scene);
        Type mapType = RuntimeType("PersistentWorldMapController");
        Component map = (Component)mapType.GetMethod("BuildDefaultMap").Invoke(null, new object[] { mapRoot });
        Invoke(map, "SetWorldActive", true);
        Transform visuals = mapRoot.transform.Find("PersistentEnvironmentRoot/BaseVisuals/WhiteboxVisuals");
        Renderer roof = fixture.Surface("V2_Ceiling", new Vector3(0, 3.25f, 0), new Vector3(8, .1f, 8));
        roof.transform.SetParent(visuals, true);
        Material original = fixture.BakedMaterial(opacity);
        roof.sharedMaterial = original;
        Renderer body = fixture.Surface("Owner", new Vector3(0, 1, 0), new Vector3(.7f, 1.8f, .5f));
        body.sharedMaterial = fixture.BakedMaterial(1f);
        fixture.Camera.transform.SetPositionAndRotation(new Vector3(0, 6.2f, 7.2f),
            Quaternion.LookRotation(new Vector3(0, .9f, -2) - new Vector3(0, 6.2f, 7.2f)));
        Component director = fixture.Camera.gameObject.AddComponent(RuntimeType("WorldCameraDirector"));
        Assert.That(Invoke(director, "EnterWorld", fixture.Camera, null, body.transform, null), Is.EqualTo(true));
        Component effect = fixture.Camera.GetComponent(RuntimeType("WorldCameraOcclusion"));
        effect.GetType().GetField("map", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(effect, map);
        InvokePrivate(effect, "PrepareFrame", Time.realtimeSinceStartup, 1f);
        Material rendered = roof.sharedMaterial;
        if (opacity == 1f)
        {
            Assert.That(rendered, Is.Not.SameAs(original));
            Assert.That(rendered.shader, Is.SameAs(original.shader), "Cutaway must retain the no-fog pass.");
            Assert.That(rendered.GetTexture("_EmissionMap"), Is.SameAs(original.GetTexture("_EmissionMap")));
            Assert.That(rendered.GetColor("_EmissionColor"), Is.EqualTo(Color.white));
            Assert.That(rendered.GetFloat("_OcclusionOpacity"), Is.Zero.Within(.001f));
            Assert.That(rendered.GetInt("_ZWrite"), Is.EqualTo(1));
            Assert.That(rendered.GetInt("_SrcBlend"), Is.EqualTo((int)BlendMode.One));
            Assert.That(rendered.GetInt("_DstBlend"), Is.EqualTo((int)BlendMode.Zero));
            Assert.That(rendered.renderQueue, Is.EqualTo(2000));
        }
        else Assert.That(rendered, Is.SameAs(original), "Transparent sheers keep their own alpha and sorting contract.");
        InvokePrivate(effect, "RestoreRenderers");
        Assert.That(roof.sharedMaterial, Is.SameAs(original));
        Assert.That(original.GetFloat("_OcclusionOpacity"), Is.EqualTo(1f));
    }

    [Test]
    public void ZeroCutawayCoverageWritesNeitherColorNorDepth()
    {
        using var fixture = new Fixture();
        Renderer front = fixture.Surface("Front", new Vector3(0, 0, 3), new Vector3(10, 10, .1f));
        Material frontMaterial = fixture.BakedMaterial(1f);
        front.sharedMaterial = frontMaterial;
        Renderer back = fixture.Surface("Back", new Vector3(0, 0, 5), new Vector3(10, 10, .1f));
        Material backMaterial = fixture.BakedMaterial(1f);
        backMaterial.SetColor("_EmissionColor", Color.blue);
        back.sharedMaterial = backMaterial;
        Color32[] solid = fixture.Capture();
        frontMaterial.SetFloat("_OcclusionOpacity", 0f);
        Color32[] cutaway = fixture.Capture();
        front.enabled = false;
        Color32[] absent = fixture.Capture();
        Assert.That(MaxPixelDifference(solid, absent), Is.GreaterThan(80));
        Assert.That(MaxPixelDifference(cutaway, absent), Is.LessThanOrEqualTo(1),
            "A fully cut roof must reveal geometry behind it, including its depth.");
    }

    [Test]
    public void CameraDepthContainsTheNearFloorWhileLightShadowCastingRemainsOff()
    {
        using var fixture = new Fixture();
        fixture.Camera.transform.SetPositionAndRotation(new Vector3(0, 3, 0), Quaternion.Euler(90, 0, 0));
        Renderer floor = fixture.Surface("V2_Floor_Baked", new Vector3(0, -.05f, 0), new Vector3(8, .1f, 8));
        Material material = fixture.BakedMaterial(1f);
        floor.sharedMaterial = material;
        floor.shadowCastingMode = ShadowCastingMode.Off;
        floor.receiveShadows = false;
        Assert.That(material.FindPass("ShadowCaster"), Is.GreaterThanOrEqualTo(0));

        material.SetShaderPassEnabled("ShadowCaster", false);
        Color32[] withoutDepthPass = fixture.Capture();
        float disabledPass = fixture.CaptureDepth()[32 * 64 + 32];
        // Metal may supply camera depth even when this material pass is
        // disabled. Remove geometry for a backend-independent negative control.
        floor.enabled = false;
        float missing = fixture.CaptureDepth()[32 * 64 + 32];
        floor.enabled = true;
        material.SetShaderPassEnabled("ShadowCaster", true);
        Color32[] withDepthPass = fixture.Capture();
        float actual = fixture.CaptureDepth()[32 * 64 + 32];
        TestContext.Out.WriteLine($"Camera depth: hidden floor={missing:F4}m, disabled pass={disabledPass:F4}m, baked floor={actual:F4}m.");
        Assert.That(missing, Is.GreaterThan(90f), "An absent floor must leave the actual camera depth at the far plane.");
        Assert.That(actual, Is.EqualTo(3f).Within(.02f),
            "Sample _CameraDepthTexture itself: the floor top is y=0 and camera y=3, with Cast Shadows still Off.");
        Assert.That(MaxPixelDifference(withoutDepthPass, withDepthPass), Is.LessThanOrEqualTo(1),
            "Enabling or disabling the material depth pass must not alter fixed-view baked radiance.");
        Assert.That(floor.shadowCastingMode, Is.EqualTo(ShadowCastingMode.Off));
    }

    [Test]
    public void CameraDepthRespectsRoofCutawayAndExcludesTransparentSheers()
    {
        using var fixture = new Fixture();
        fixture.Camera.transform.SetPositionAndRotation(new Vector3(0, 3, 0), Quaternion.Euler(90, 0, 0));
        Renderer floor = fixture.Surface("V2_Floor_Baked", new Vector3(0, -.05f, 0), new Vector3(8, .1f, 8));
        floor.sharedMaterial = fixture.BakedMaterial(1f);
        floor.shadowCastingMode = ShadowCastingMode.Off;
        Renderer roof = fixture.Surface("V2_Ceiling", new Vector3(0, 1.5f, 0), new Vector3(8, .1f, 8));
        Material material = fixture.BakedMaterial(1f);
        roof.sharedMaterial = material;
        roof.shadowCastingMode = ShadowCastingMode.Off;
        Assert.That(fixture.CaptureDepth()[32 * 64 + 32], Is.EqualTo(1.45f).Within(.02f));
        material.SetFloat("_OcclusionOpacity", 0f);
        float[] cutaway = fixture.CaptureDepth();
        Assert.That(cutaway.All(value => Mathf.Abs(value - 3f) < .02f), Is.True,
            "Roof coverage zero must leave the underlying floor in the actual camera depth texture.");
        material.SetFloat("_OcclusionOpacity", .5f);
        float[] partial = fixture.CaptureDepth();
        int roofPixels = partial.Count(value => Mathf.Abs(value - 1.45f) < .02f);
        Assert.That(roofPixels, Is.InRange(1800, 2300), "Half cutaway must dither depth instead of blocking every pixel.");

        roof.sharedMaterial = fixture.BakedMaterial(.38f);
        float[] sheer = fixture.CaptureDepth();
        Assert.That(sheer.All(value => Mathf.Abs(value - 3f) < .02f), Is.True,
            "Transparent sheers keep the background depth used by the portrait effect.");
    }

    [Test]
    public void CameraDepthPassDoesNotAddRealtimeShadowsWhenImporterDisablesCasting()
    {
        using var fixture = new Fixture();
        ShadowQuality oldShadows = QualitySettings.shadows;
        float oldDistance = QualitySettings.shadowDistance;
        int oldPixelLights = QualitySettings.pixelLightCount;
        try
        {
            QualitySettings.shadows = ShadowQuality.All;
            QualitySettings.shadowDistance = 30f;
            QualitySettings.pixelLightCount = Math.Max(1, oldPixelLights);
            fixture.Camera.renderingPath = RenderingPath.Forward;
            fixture.Camera.transform.SetPositionAndRotation(new Vector3(0, 5, -6),
                Quaternion.LookRotation(new Vector3(0, 0, 0) - new Vector3(0, 5, -6)));
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = Color.white * .05f;
            var light = new GameObject("AvatarDirectionalLightControl").AddComponent<Light>();
            SceneManager.MoveGameObjectToScene(light.gameObject, fixture.Scene);
            light.type = LightType.Directional;
            light.renderMode = LightRenderMode.ForcePixel;
            light.cullingMask = -1;
            light.intensity = 1f;
            light.shadows = LightShadows.Hard;
            light.shadowStrength = 1f;
            light.transform.rotation = Quaternion.Euler(50, -30, 0);
            Renderer ground = fixture.Surface("StandardAvatarLightingReceiver", new Vector3(0, -.05f, 0),
                new Vector3(10, .1f, 10));
            ground.sharedMaterial = fixture.NewMaterial(Shader.Find("Standard"));
            ground.sharedMaterial.color = Color.white;
            ground.sharedMaterial.SetFloat("_Glossiness", 0f);
            Renderer furniture = fixture.Surface("V2_Furniture_Baked", new Vector3(0, 1, 0), Vector3.one * 1.5f);
            Material material = fixture.BakedMaterial(1f);
            furniture.sharedMaterial = material;
            furniture.shadowCastingMode = ShadowCastingMode.Off;
            material.SetShaderPassEnabled("ShadowCaster", false);
            Color32[] absentPass = fixture.Capture();
            material.SetShaderPassEnabled("ShadowCaster", true);
            Color32[] cameraDepthOnly = fixture.Capture();
            Assert.That(MaxPixelDifference(absentPass, cameraDepthOnly), Is.LessThanOrEqualTo(1),
                "A camera-depth pass must not add light shadows when renderer casting remains Off.");
            furniture.shadowCastingMode = ShadowCastingMode.On;
            Color32[] shadowPositiveControl = fixture.Capture();
            Assert.That(MaxPixelDifference(cameraDepthOnly, shadowPositiveControl), Is.GreaterThan(5),
                "The lit Standard receiver must prove this fixture detects accidental room shadow casting.");
        }
        finally
        {
            QualitySettings.shadows = oldShadows;
            QualitySettings.shadowDistance = oldDistance;
            QualitySettings.pixelLightCount = oldPixelLights;
        }
    }

    private static int MaxPixelDifference(Color32[] a, Color32[] b) => a.Zip(b, (x, y) =>
        Math.Max(Math.Abs(x.r - y.r), Math.Max(Math.Abs(x.g - y.g), Math.Abs(x.b - y.b)))).Max();
    private static Type RuntimeType(string name) => Type.GetType("Maaso.World." + name + ", Assembly-CSharp", true);
    private static object Invoke(object target, string method, params object[] args) =>
        target.GetType().GetMethod(method, BindingFlags.Instance | BindingFlags.Public).Invoke(target, args);
    private static object InvokePrivate(object target, string method, params object[] args) =>
        target.GetType().GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(target, args);

    private sealed class Fixture : IDisposable
    {
        public readonly Scene Scene;
        public readonly Camera Camera;
        private readonly bool previousFog;
        private readonly FogMode previousFogMode;
        private readonly float previousFogDensity;
        private readonly Color previousFogColor;
        private readonly AmbientMode previousAmbientMode;
        private readonly Color previousAmbientLight;
        private readonly List<Object> assets = new();

        public Fixture()
        {
            Assert.That(QualitySettings.activeColorSpace, Is.EqualTo(ColorSpace.Linear));
            previousFog = RenderSettings.fog;
            previousFogMode = RenderSettings.fogMode;
            previousFogDensity = RenderSettings.fogDensity;
            previousFogColor = RenderSettings.fogColor;
            previousAmbientMode = RenderSettings.ambientMode;
            previousAmbientLight = RenderSettings.ambientLight;
            // Preview scenes work in EditMode without replacing or saving an
            // existing untitled scene. Every test object is moved explicitly.
            Scene = EditorSceneManager.NewPreviewScene();
            RenderSettings.fog = false;
            var root = new GameObject("CoastalShaderTestCamera");
            SceneManager.MoveGameObjectToScene(root, Scene);
            Camera = root.AddComponent<Camera>();
            Camera.enabled = false;
            Camera.scene = Scene;
            Camera.clearFlags = CameraClearFlags.SolidColor;
            Camera.backgroundColor = Color.black;
            Camera.allowHDR = false;
            Camera.allowMSAA = false;
            Camera.fieldOfView = 50f;
            Camera.aspect = 1f;
            Camera.nearClipPlane = .05f;
            Camera.farClipPlane = 100f;
        }

        public Renderer Surface(string name, Vector3 position, Vector3 scale)
        {
            GameObject value = GameObject.CreatePrimitive(PrimitiveType.Cube);
            SceneManager.MoveGameObjectToScene(value, Scene);
            value.name = name;
            value.transform.SetPositionAndRotation(position, Quaternion.identity);
            value.transform.localScale = scale;
            Object.DestroyImmediate(value.GetComponent<Collider>());
            return value.GetComponent<Renderer>();
        }

        public Material NewMaterial(Shader shader)
        {
            Assert.That(shader, Is.Not.Null);
            var material = new Material(shader);
            assets.Add(material);
            return material;
        }

        public Material BakedMaterial(float opacity)
        {
            Material material = NewMaterial(Resources.Load<Shader>("CoastalBakedRadiance"));
            var texture = new Texture2D(2, 2, TextureFormat.RGBA32, false, false);
            texture.SetPixels32(Enumerable.Repeat(new Color32(208, 164, 112, 255), 4).ToArray());
            texture.Apply();
            assets.Add(texture);
            Type importer = Type.GetType("Maaso.World.Editor.CoastalRoomV2Importer, Assembly-CSharp-Editor", true);
            importer.GetMethod("ApplyBakedMaterial").Invoke(null, new object[] { material, texture, opacity });
            return material;
        }

        public Color32[] Capture()
        {
            RenderTexture active = RenderTexture.active;
            RenderTexture cameraTarget = Camera.targetTexture;
            RenderTexture target = RenderTexture.GetTemporary(64, 64, 24,
                RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
            var image = new Texture2D(64, 64, TextureFormat.RGB24, false, false);
            try
            {
                Camera.targetTexture = target;
                Camera.Render();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, 64, 64), 0, 0);
                image.Apply();
                return image.GetPixels32();
            }
            finally
            {
                Camera.targetTexture = cameraTarget;
                RenderTexture.active = active;
                RenderTexture.ReleaseTemporary(target);
                Object.DestroyImmediate(image);
            }
        }

        public float[] CaptureDepth()
        {
            Assert.That(SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.RFloat), Is.True);
            Shader shader = AssetDatabase.LoadAssetAtPath<Shader>(
                "Assets/Tests/EditMode/CoastalDepthProbe.shader");
            Material probe = NewMaterial(shader);
            Assert.That(shader.isSupported, Is.True);
            Assert.That(ShaderUtil.ShaderHasError(shader), Is.False);
            RenderTexture active = RenderTexture.active;
            RenderTexture target = RenderTexture.GetTemporary(64, 64, 0,
                RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear);
            var image = new Texture2D(64, 64, TextureFormat.RFloat, false, true);
            var commands = new CommandBuffer { name = "Coastal actual camera depth probe" };
            try
            {
                Camera.depthTextureMode |= DepthTextureMode.Depth;
                // Sample during this camera's render, before another scene or
                // editor camera can replace the global depth binding/parameters.
                commands.Blit(BuiltinRenderTextureType.None, target, probe);
                Camera.AddCommandBuffer(CameraEvent.AfterDepthTexture, commands);
                Capture();
                RenderTexture.active = target;
                image.ReadPixels(new Rect(0, 0, 64, 64), 0, 0);
                image.Apply();
                return image.GetRawTextureData<float>().ToArray();
            }
            finally
            {
                Camera.RemoveCommandBuffer(CameraEvent.AfterDepthTexture, commands);
                commands.Release();
                RenderTexture.active = active;
                RenderTexture.ReleaseTemporary(target);
                Object.DestroyImmediate(image);
            }
        }

        public void Dispose()
        {
            EditorSceneManager.ClosePreviewScene(Scene);
            RenderSettings.fog = previousFog;
            RenderSettings.fogMode = previousFogMode;
            RenderSettings.fogDensity = previousFogDensity;
            RenderSettings.fogColor = previousFogColor;
            RenderSettings.ambientMode = previousAmbientMode;
            RenderSettings.ambientLight = previousAmbientLight;
            foreach (Object asset in assets) Object.DestroyImmediate(asset);
        }
    }
}
