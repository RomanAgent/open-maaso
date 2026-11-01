using System;
using System.IO;
using System.Reflection;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using Object = UnityEngine.Object;

public sealed class DesktopTextureQualityTests
{
    private static object Runtime(string method, params object[] args) =>
        Type.GetType("Maaso.Avatar.DesktopTextureQuality, Maaso.VrmBridge", true)
            .GetMethod(method, BindingFlags.Public | BindingFlags.Static).Invoke(null, args);

    [Test]
    public void BundledVrmTexturesRetainEmbeddedImageResolutionWithoutGpuCompression()
    {
        const string path = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        byte[] glb = File.ReadAllBytes(path);
        int jsonLength = BitConverter.ToInt32(glb, 12);
        JObject document = JObject.Parse(Encoding.UTF8.GetString(glb, 20, jsonLength));
        int binaryStart = 20 + jsonLength + 8;
        var images = document["images"].ToArray();
        var remaps = AssetImporter.GetAtPath(path).GetExternalObjectMap()
            .Where(pair => typeof(Texture).IsAssignableFrom(pair.Key.type)).ToArray();
        Assert.That(remaps.Length, Is.GreaterThan(10), "Joy textures must use the native external import path.");
        GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(path);
        Assert.That(prefab, Is.Not.Null);
        Texture[] materialTextures = prefab.GetComponentsInChildren<Renderer>(true)
            .SelectMany(renderer => renderer.sharedMaterials).Where(material => material != null).Distinct()
            .SelectMany(material => material.GetTexturePropertyNames().Select(material.GetTexture))
            .Where(texture => texture != null).Distinct().ToArray();
        Assert.That(materialTextures.Length, Is.GreaterThan(10));
        foreach (Texture texture in materialTextures)
            Assert.That(remaps.Any(pair => pair.Value == texture), Is.True,
                "Material texture bypasses the reviewed external remaps: " + texture.name);

        bool desktopActive = BuildPipeline.GetBuildTargetGroup(EditorUserBuildSettings.activeBuildTarget)
            == BuildTargetGroup.Standalone;
        foreach (var remap in remaps)
        {
            Assert.That(remap.Value, Is.InstanceOf<Texture2D>(), remap.Key.name);
            var texture = (Texture2D)remap.Value;
            string name = remap.Key.name;
            // Resolve the importer key, not a filename prefix: UniGLTF appends
            // a role suffix and may duplicate a glTF texture for another sampler.
            string imageName = Regex.Replace(name, @"\.(normal|standard|linear)$", "");
            imageName = Regex.Replace(imageName, @"__UNIGLTF__DUPLICATED__\d+$", "");
            JToken image = name == "thumbnail__VRM10"
                ? document["images"][document["extensions"]["VRMC_vrm"]["meta"]["thumbnailImage"].Value<int>()]
                : images.SingleOrDefault(entry => entry["name"].Value<string>() == imageName);
            Assert.That(image, Is.Not.Null, name);
            Assert.That(image["mimeType"].Value<string>(), Is.EqualTo("image/png"), name);
            JToken view = document["bufferViews"][image["bufferView"].Value<int>()];
            int start = binaryStart + (view["byteOffset"]?.Value<int>() ?? 0);
            int width = (glb[start + 16] << 24) | (glb[start + 17] << 16) | (glb[start + 18] << 8) | glb[start + 19];
            int height = (glb[start + 20] << 24) | (glb[start + 21] << 16) | (glb[start + 22] << 8) | glb[start + 23];
            string texturePath = AssetDatabase.GetAssetPath(texture);
            Assert.That(texturePath, Does.StartWith("Assets/MaasoAvatar/Models/Default/Joy.Textures/"), name);
            var importer = AssetImporter.GetAtPath(texturePath) as TextureImporter;
            Assert.That(importer, Is.Not.Null, name);
            importer.GetSourceTextureWidthAndHeight(out int sourceWidth, out int sourceHeight);
            Assert.That(sourceWidth, Is.EqualTo(width), name);
            Assert.That(sourceHeight, Is.EqualTo(height), name);
            Assert.That(importer.npotScale, Is.EqualTo(TextureImporterNPOTScale.None), name);
            TextureImporterPlatformSettings desktop = importer.GetPlatformTextureSettings("Standalone");
            Assert.That(desktop.overridden, Is.True, name);
            Assert.That(desktop.maxTextureSize, Is.GreaterThanOrEqualTo(Mathf.Max(width, height)), name);
            Assert.That(desktop.format, Is.EqualTo(TextureImporterFormat.RGBA32), name);
            Assert.That(desktop.textureCompression, Is.EqualTo(TextureImporterCompression.Uncompressed), name);
            Assert.That(desktop.crunchedCompression, Is.False, name);

            // Extraction re-encodes PNGs. Compare decoded source pixels instead
            // of encoded bytes. Packed Standard maps deliberately convert glTF
            // metallic/roughness channels, so their dimensions/settings are checked above.
            if (!name.EndsWith(".standard", StringComparison.Ordinal))
            {
                var embeddedImage = new Texture2D(2, 2, TextureFormat.RGBA32, false, true);
                var extractedImage = new Texture2D(2, 2, TextureFormat.RGBA32, false, true);
                try
                {
                    byte[] sourcePng = new byte[view["byteLength"].Value<int>()];
                    Buffer.BlockCopy(glb, start, sourcePng, 0, sourcePng.Length);
                    Assert.That(embeddedImage.LoadImage(sourcePng), Is.True, name);
                    Assert.That(extractedImage.LoadImage(File.ReadAllBytes(texturePath)), Is.True, name);
                    Color32[] original = embeddedImage.GetPixels32();
                    Color32[] extracted = extractedImage.GetPixels32();
                    Assert.That(extracted.Length, Is.EqualTo(original.Length), name);
                    int mismatch = -1;
                    for (int pixel = 0; pixel < original.Length; pixel++)
                    {
                        if (original[pixel].r != extracted[pixel].r || original[pixel].g != extracted[pixel].g ||
                            original[pixel].b != extracted[pixel].b || original[pixel].a != extracted[pixel].a)
                        {
                            mismatch = pixel;
                            break;
                        }
                    }
                    Assert.That(mismatch, Is.EqualTo(-1), name + " must retain the original image pixels.");
                }
                finally
                {
                    Object.DestroyImmediate(embeddedImage);
                    Object.DestroyImmediate(extractedImage);
                }
            }

            // An iOS-active editor correctly exposes its capped ASTC texture.
            // Validate desktop GPU data only when that platform is actually imported.
            if (desktopActive)
            {
                Assert.That(texture.width, Is.EqualTo(width), name);
                Assert.That(texture.height, Is.EqualTo(height), name);
                Assert.That(GraphicsFormatUtility.IsCompressedFormat(texture.graphicsFormat), Is.False, name);
            }
            Debug.Log($"[DesktopTextureQuality] Bundled VRM {name}: source {width}x{height}, Standalone RGBA32, active {texture.graphicsFormat}");
        }
    }

    [TestCase(RuntimePlatform.OSXPlayer, true)]
    [TestCase(RuntimePlatform.WindowsPlayer, true)]
    [TestCase(RuntimePlatform.LinuxPlayer, true)]
    [TestCase(RuntimePlatform.IPhonePlayer, false)]
    [TestCase(RuntimePlatform.Android, false)]
    [TestCase(RuntimePlatform.OSXEditor, false)]
    public void AvatarSamplingPreservesSourcePixelsAndMobileSettings(RuntimePlatform platform, bool desktop)
    {
        var root = new GameObject("DesktopTextureQualityFixture");
        var texture = new Texture2D(128, 64, TextureFormat.RGBA32, true)
        {
            filterMode = FilterMode.Bilinear,
            anisoLevel = 2,
        };
        var material = new Material(Shader.Find("Standard")) { mainTexture = texture };
        root.AddComponent<MeshRenderer>().sharedMaterial = material;
        try
        {
            int mipCount = texture.mipmapCount;
            Runtime("ApplyAvatarTextures", root, platform);
            Assert.That(texture.width, Is.EqualTo(128));
            Assert.That(texture.height, Is.EqualTo(64));
            Assert.That(texture.mipmapCount, Is.EqualTo(mipCount));
            Assert.That(texture.format, Is.EqualTo(TextureFormat.RGBA32));
            Assert.That(material.mainTexture, Is.SameAs(texture), "Do not duplicate or upscale the source texture.");
            Assert.That(texture.filterMode, Is.EqualTo(desktop ? FilterMode.Trilinear : FilterMode.Bilinear));
            Assert.That(texture.anisoLevel, Is.EqualTo(desktop ? 16 : 2));
        }
        finally
        {
            Object.DestroyImmediate(root);
            Object.DestroyImmediate(material);
            Object.DestroyImmediate(texture);
        }
    }

    [Test]
    public void DesktopRuntimeUsesFullMipResolutionWithoutChangingMobileQuality()
    {
        int originalMipLimit = QualitySettings.globalTextureMipmapLimit;
        AnisotropicFiltering originalFiltering = QualitySettings.anisotropicFiltering;
        try
        {
            QualitySettings.globalTextureMipmapLimit = 1;
            QualitySettings.anisotropicFiltering = AnisotropicFiltering.Enable;
            Runtime("ApplyRuntimeQuality", RuntimePlatform.IPhonePlayer);
            Assert.That(QualitySettings.globalTextureMipmapLimit, Is.EqualTo(1));
            Assert.That(QualitySettings.anisotropicFiltering, Is.EqualTo(AnisotropicFiltering.Enable));
            Runtime("ApplyRuntimeQuality", RuntimePlatform.OSXPlayer);
            Assert.That(QualitySettings.globalTextureMipmapLimit, Is.Zero);
            Assert.That(QualitySettings.anisotropicFiltering, Is.EqualTo(AnisotropicFiltering.ForceEnable));
        }
        finally
        {
            QualitySettings.globalTextureMipmapLimit = originalMipLimit;
            QualitySettings.anisotropicFiltering = originalFiltering;
            Texture.SetGlobalAnisotropicFilteringLimits(-1, -1);
        }
    }

    [Test]
    public void StandaloneImportPreservesNativeSizeAndLeavesMobileOverridesUntouched()
    {
        string path = "Assets/__DesktopTextureQuality_" + Guid.NewGuid().ToString("N") + ".png";
        var source = new Texture2D(128, 64, TextureFormat.RGBA32, false);
        try
        {
            File.WriteAllBytes(path, source.EncodeToPNG());
            AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
            var importer = (TextureImporter)AssetImporter.GetAtPath(path);
            importer.maxTextureSize = 32;
            importer.npotScale = TextureImporterNPOTScale.None;
            importer.filterMode = FilterMode.Bilinear;
            importer.anisoLevel = 2;
            importer.SetPlatformTextureSettings(new TextureImporterPlatformSettings
            {
                name = "iPhone", overridden = true, maxTextureSize = 32,
                format = TextureImporterFormat.ASTC_8x8,
            });
            string mobileBefore = JsonUtility.ToJson(importer.GetPlatformTextureSettings("iPhone"));
            MethodInfo configure = Type.GetType(
                "Maaso.Avatar.Editor.DesktopTextureImportPolicy, Assembly-CSharp-Editor", true)
                .GetMethod("ConfigureStandalone");
            Assert.That(configure.Invoke(null, new object[] { importer }), Is.True);
            importer.SaveAndReimport();
            Assert.That(configure.Invoke(null, new object[] { importer }), Is.False, "Import policy must be idempotent.");
            TextureImporterPlatformSettings desktop = importer.GetPlatformTextureSettings("Standalone");
            Assert.That(desktop.overridden, Is.True);
            Assert.That(desktop.maxTextureSize, Is.EqualTo(128));
            Assert.That(desktop.format, Is.EqualTo(TextureImporterFormat.RGBA32));
            Assert.That(desktop.textureCompression, Is.EqualTo(TextureImporterCompression.Uncompressed));
            Assert.That(desktop.crunchedCompression, Is.False);
            Assert.That(importer.maxTextureSize, Is.EqualTo(32));
            Assert.That(importer.filterMode, Is.EqualTo(FilterMode.Bilinear));
            Assert.That(importer.anisoLevel, Is.EqualTo(2));
            Assert.That(JsonUtility.ToJson(importer.GetPlatformTextureSettings("iPhone")), Is.EqualTo(mobileBefore));
            if (BuildPipeline.GetBuildTargetGroup(EditorUserBuildSettings.activeBuildTarget) == BuildTargetGroup.Standalone)
            {
                Texture2D imported = AssetDatabase.LoadAssetAtPath<Texture2D>(path);
                Assert.That(imported.width, Is.EqualTo(128));
                Assert.That(imported.height, Is.EqualTo(64));
                Assert.That(imported.format, Is.EqualTo(TextureFormat.RGBA32));
            }
        }
        finally
        {
            AssetDatabase.DeleteAsset(path);
            Object.DestroyImmediate(source);
        }
    }
}
