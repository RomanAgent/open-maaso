using System;
using System.IO;
using Maaso.Avatar.Editor;
using NUnit.Framework;
using UniGLTF;
using UnityEditor;
using UnityEngine;

public sealed class MaasoJoyTextureImporterTests
{
    private string path;

    [SetUp]
    public void CreateTexture()
    {
        path = "Assets/JoyTextureImporterTest_" + Guid.NewGuid().ToString("N") + ".png";
        var source = new Texture2D(4096, 4, TextureFormat.RGBA32, false, true);
        try { File.WriteAllBytes(path, source.EncodeToPNG()); }
        finally { UnityEngine.Object.DestroyImmediate(source); }
        AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
    }

    [TearDown]
    public void RemoveTexture() => AssetDatabase.DeleteAsset(path);

    [TestCase(TextureImportTypes.NormalMap, TextureImporterType.NormalMap, false)]
    [TestCase(TextureImportTypes.StandardMap, TextureImporterType.Default, false)]
    [TestCase(TextureImportTypes.Linear, TextureImporterType.Default, false)]
    [TestCase(TextureImportTypes.sRGB, TextureImporterType.Default, true)]
    public void DescriptorRoleControlsNativeEncodingAndColorSpace(
        TextureImportTypes role, TextureImporterType expectedType, bool expectedSrgb)
    {
        var importer = (TextureImporter)AssetImporter.GetAtPath(path);
        MaasoJoyTextureImporter.ApplyTextureSettings(importer, Descriptor(role));
        Assert.That(importer.textureType, Is.EqualTo(expectedType));
        Assert.That(importer.sRGBTexture, Is.EqualTo(expectedSrgb));
        Assert.That(importer.convertToNormalmap, Is.False, "RGB normals must not be interpreted as height maps.");
        Assert.That(importer.flipGreenChannel, Is.False, "glTF OpenGL Y must be preserved.");
        Assert.That(importer.alphaIsTransparency, Is.False, "Do not rewrite glTF alpha/normal channels.");
    }

    [Test]
    public void DesktopKeeps4096SourceWhileBothMobilePlatformsUse2048Astc()
    {
        var importer = (TextureImporter)AssetImporter.GetAtPath(path);
        MaasoJoyTextureImporter.ApplyTextureSettings(importer, Descriptor(TextureImportTypes.NormalMap));
        var desktop = importer.GetPlatformTextureSettings("Standalone");
        Assert.That(desktop.overridden, Is.True);
        Assert.That(desktop.maxTextureSize, Is.EqualTo(4096));
        Assert.That(desktop.format, Is.EqualTo(TextureImporterFormat.RGBA32));
        Assert.That(desktop.textureCompression, Is.EqualTo(TextureImporterCompression.Uncompressed));
        foreach (string platform in new[] { "iPhone", "Android" })
        {
            var mobile = importer.GetPlatformTextureSettings(platform);
            Assert.That(mobile.overridden, Is.True);
            Assert.That(mobile.maxTextureSize, Is.EqualTo(2048));
            Assert.That(mobile.format, Is.EqualTo(TextureImporterFormat.ASTC_4x4));
            Assert.That(mobile.compressionQuality, Is.EqualTo(100));
        }
    }

    [Test]
    public void SamplerIsPreservedWithoutRescalingNonPowerOfTwoTextures()
    {
        var importer = (TextureImporter)AssetImporter.GetAtPath(path);
        MaasoJoyTextureImporter.ApplyTextureSettings(importer, Descriptor(TextureImportTypes.sRGB));
        Assert.That(importer.mipmapEnabled, Is.False);
        Assert.That(importer.filterMode, Is.EqualTo(FilterMode.Trilinear));
        Assert.That(importer.wrapModeU, Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(importer.wrapModeV, Is.EqualTo(TextureWrapMode.Mirror));
        Assert.That(importer.npotScale, Is.EqualTo(TextureImporterNPOTScale.None));
    }

    [Test]
    public void GeneratedDirectoryBoundaryDoesNotClaimOtherModelsOrSiblingDirectories()
    {
        Assert.That(MaasoJoyTextureImporter.IsOwnedTexturePath(
            MaasoJoyTextureImporter.TextureDirectory + "/head_normal.png"), Is.True);
        Assert.That(MaasoJoyTextureImporter.IsOwnedTexturePath(
            MaasoJoyTextureImporter.TextureDirectory + "Backup/head_normal.png"), Is.False);
        Assert.That(MaasoJoyTextureImporter.IsOwnedTexturePath(
            "Assets/OtherAvatar/head_normal.png"), Is.False);
        Assert.That(MaasoJoyTextureImporter.IsOwnedTexturePath(null), Is.False);
    }

    private static TextureDescriptor Descriptor(TextureImportTypes role) => new TextureDescriptor(
        "test", Vector2.zero, Vector2.one,
        new SamplerParam(TextureWrapMode.Clamp, TextureWrapMode.Mirror, FilterMode.Trilinear, false),
        role, 1f, 1f, null, null, null, null, null, null);
}
