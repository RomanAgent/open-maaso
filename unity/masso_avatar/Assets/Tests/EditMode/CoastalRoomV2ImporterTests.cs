using System;
using System.IO;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.Rendering;

public sealed class CoastalRoomV2ImporterTests
{
    private const string ImporterType = "Maaso.World.Editor.CoastalRoomV2Importer, Assembly-CSharp-Editor";

    [Test]
    public void ManifestRequiresEightMetresNoBedAndAllComparisonCameras()
    {
        Assert.That(Invoke("ParseManifest", ValidManifest()), Is.Not.Null);
        Reject(ValidManifest().Replace("\"roomSize\":8", "\"roomSize\":12"));
        Reject(ValidManifest().Replace("\"bedCount\":0", "\"bedCount\":1"));
        Reject(ValidManifest().Replace("\"floor_detail\"", "\"unexpected_view\""));
        Reject(ValidManifest().Replace("\"V2_Test\"", "\"V2_Bed_Platform\""));
    }

    [TestCase("../outside.png")]
    [TestCase("/tmp/outside.png")]
    [TestCase("Assets/Other/outside.png")]
    [TestCase("https://example.com/atlas.png")]
    [TestCase("nested\\atlas.png")]
    [TestCase("atlas.exr")]
    public void AtlasPathsCannotEscapeTheBundledBakeDirectory(string path)
    {
        TargetInvocationException error = Assert.Throws<TargetInvocationException>(() => Invoke("ResolveTexturePath", path));
        Assert.That(error.InnerException, Is.TypeOf<InvalidDataException>());
    }

    [Test]
    public void LocalAtlasPathsResolveWithoutChangingTheResourceRoot()
    {
        const string expected = "Assets/MaasoWorld/PersonalSpace/CoastalV2/Baked_Floor.png";
        Assert.That(Invoke("ResolveTexturePath", "Baked_Floor.png"), Is.EqualTo(expected));
        Assert.That(Invoke("ResolveTexturePath", expected), Is.EqualTo(expected));
    }

    [Test]
    public void ManifestRejectsMissingAtlasBindingAndDegenerateCamera()
    {
        Reject(ValidManifest().Replace("\"material\":\"Baked_Test\"", "\"material\":\"Baked_Missing\""));
        Reject(ValidManifest().Replace("\"target\":[0,4,1]", "\"target\":[0,-3,1]"));
        Reject(ValidManifest().Replace("\"opacity\":1", "\"opacity\":1.1"));
    }

    [Test]
    public void BlenderCameraAxesKeepTheOceanOnUnityNegativeZ()
    {
        Assert.That(Invoke("BlenderToUnity", new float[] { 1, 2, 3 }), Is.EqualTo(new Vector3(-1, 3, -2)));
        Assert.That(Invoke("BlenderToUnity", new float[] { 0, 4, 1.45f }), Is.EqualTo(new Vector3(0, 1.45f, -4)));
        Vector3 oceanForward = (Vector3)Invoke("BlenderToUnity", new float[] { 0, 1, 0 });
        Vector3 authoredRight = (Vector3)Invoke("BlenderToUnity", new float[] { 1, 0, 0 });
        Vector3 cameraRight = Vector3.Cross(Vector3.up, oceanForward).normalized;
        Assert.That(Vector3.Dot(authoredRight, cameraRight), Is.EqualTo(1f).Within(.0001f),
            "The east sofa must remain screen-right while looking at the sea; mapping +X directly mirrors the room.");
    }

    [Test]
    public void CameraLensUsesHorizontalSensorFitAtLandscapeAspect()
    {
        Type capture = Type.GetType("Maaso.World.Editor.CoastalRoomV2Capture, Assembly-CSharp-Editor");
        Assert.That(capture, Is.Not.Null);
        MethodInfo method = capture.GetMethod("VerticalFieldOfView", BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null);
        float vertical = (float)method.Invoke(null, new object[] { 24f, 16f / 9f });
        Assert.That(vertical, Is.EqualTo(45.747f).Within(.01f),
            "A 24 mm / 36 mm Blender camera must not be interpreted as a 73-degree vertical lens.");
    }

    [TestCase(1f, 0f, 1)]
    [TestCase(.38f, 2f, 0)]
    public void BakedRadianceNeverReceivesAnotherTintOrLightingPass(float opacity, float mode, int zWrite)
    {
        var material = new Material(Shader.Find("Standard"));
        var texture = new Texture2D(2, 2);
        try
        {
            material.color = Color.yellow;
            material.SetColor("_EmissionColor", Color.red * 3f);
            material.EnableKeyword("_METALLICGLOSSMAP");
            Invoke("ApplyBakedMaterial", material, texture, opacity);
            Assert.That(material.color, Is.EqualTo(new Color(0, 0, 0, opacity)));
            Assert.That(material.GetColor("_EmissionColor"), Is.EqualTo(Color.white));
            Assert.That(material.mainTexture, Is.SameAs(texture));
            Assert.That(material.GetTexture("_EmissionMap"), Is.SameAs(texture));
            Assert.That(material.GetFloat("_Mode"), Is.EqualTo(mode));
            Assert.That(material.GetInt("_ZWrite"), Is.EqualTo(zWrite));
            Assert.That(material.GetFloat("_GlossyReflections"), Is.Zero);
            Assert.That(material.GetFloat("_SpecularHighlights"), Is.Zero);
            Assert.That(material.IsKeywordEnabled("_METALLICGLOSSMAP"), Is.False);
            Assert.That(material.shader.name, Is.EqualTo("Maaso/CoastalBakedRadiance"));
            Assert.That(material.passCount, Is.EqualTo(2), "Only baked color and camera depth are rendered.");
            Assert.That(material.FindPass("ShadowCaster"), Is.GreaterThanOrEqualTo(0));
            Assert.That(material.GetFloat("_OcclusionOpacity"), Is.EqualTo(1f));
            Assert.That(material.GetTag("RenderType", false), Is.EqualTo(opacity < 1f ? "Transparent" : "Opaque"));
            Assert.That(material.renderQueue, Is.EqualTo((int)(opacity < 1f ? RenderQueue.Transparent : RenderQueue.Geometry)));
            Assert.That(material.globalIlluminationFlags, Is.EqualTo(MaterialGlobalIlluminationFlags.None));
            Assert.That(material.GetInt("_SrcBlend"), Is.EqualTo((int)(opacity < 1f ? BlendMode.SrcAlpha : BlendMode.One)));
            Assert.That(material.GetInt("_DstBlend"), Is.EqualTo((int)(opacity < 1f ? BlendMode.OneMinusSrcAlpha : BlendMode.Zero)));
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(material);
            UnityEngine.Object.DestroyImmediate(texture);
        }
    }

    private static string ValidManifest()
    {
        string cameras = string.Join(",", new[] { "sea", "interior", "west", "east", "linen_detail", "floor_detail" }
            .Select(name => "{\"name\":\"" + name + "\",\"position\":[0,-3,1],\"target\":[0,4,1],\"lens\":24}"));
        return "{\"version\":2,\"roomSize\":8,\"roomHeight\":3.2,\"bedCount\":0," +
            "\"materials\":[{\"name\":\"Baked_Test\",\"texture\":\"Baked_Test.png\",\"opacity\":1}]," +
            "\"meshes\":[{\"name\":\"V2_Test\",\"material\":\"Baked_Test\",\"triangles\":12}],\"cameras\":[" + cameras + "]}";
    }

    private static void Reject(string json)
    {
        TargetInvocationException error = Assert.Throws<TargetInvocationException>(() => Invoke("ParseManifest", json));
        Assert.That(error.InnerException, Is.TypeOf<InvalidDataException>());
    }

    private static object Invoke(string methodName, params object[] arguments)
    {
        Type type = Type.GetType(ImporterType);
        Assert.That(type, Is.Not.Null, ImporterType);
        MethodInfo method = type.GetMethod(methodName, BindingFlags.Public | BindingFlags.Static);
        Assert.That(method, Is.Not.Null, methodName);
        return method.Invoke(null, arguments);
    }
}
