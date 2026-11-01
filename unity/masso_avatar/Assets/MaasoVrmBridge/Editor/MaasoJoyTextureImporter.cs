using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using UniGLTF;
using UniVRM10;
using UnityEditor;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Materializes Joy's embedded textures so Unity, rather than Texture2D.LoadImage,
    /// encodes normal maps for the active build platform. Call before installing the
    /// bundled avatar into the existing scene; do not rebuild the room.
    /// This deliberately does not change runtime imports of external VRM files.
    /// </summary>
    public static class MaasoJoyTextureImporter
    {
        public const string VrmPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        public const string TextureDirectory = "Assets/MaasoAvatar/Models/Default/Joy.Textures";
        public const int MobileTextureLimit = 2048;

        [Serializable]
        public sealed class TextureReport
        {
            public string name;
            public string assetPath;
            public string role;
            public int width;
            public int height;
            public string activeFormat;
        }

        [Serializable]
        public sealed class ImportReport
        {
            public string vrmPath;
            public string vrmSha256;
            public string activeBuildTarget;
            public int normalTextureCount;
            public int materialNormalBindingCount;
            public int mobileMaxTextureSize = MobileTextureLimit;
            public bool sourceVrmUnchanged;
            public bool importedPrefabValidated;
            public bool runtimeExternalVrmCovered;
            public TextureReport[] textures;
        }

        [MenuItem("Maaso/Avatar/Prepare Joy Platform Textures")]
        public static void PrepareJoyTextures()
        {
            ImportReport report = Prepare();
            Debug.Log("[MaasoJoyTextureImporter] " + JsonUtility.ToJson(report, true));
        }

        /// <summary>Synchronous batch entry; accepts optional -maasoJoyTextureReport.</summary>
        public static void RunFromCommandLine()
        {
            ImportReport report = Prepare();
            string[] arguments = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(arguments, "-maasoJoyTextureReport");
            if (index >= 0)
            {
                if (index + 1 >= arguments.Length || arguments[index + 1].StartsWith("-"))
                    throw new ArgumentException("-maasoJoyTextureReport requires an output path.");
                string path = Path.GetFullPath(arguments[index + 1]);
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, JsonUtility.ToJson(report, true));
            }
            Debug.Log("[MaasoJoyTextureImporter] " + JsonUtility.ToJson(report, true));
        }

        public static ImportReport Prepare()
        {
            if (EditorApplication.isPlayingOrWillChangePlaymode)
                throw new InvalidOperationException("Prepare Joy textures outside Play Mode.");
            if (!File.Exists(VrmPath)) throw new FileNotFoundException("Bundled Joy VRM is missing.", VrmPath);
            string sourceHash = Sha256(VrmPath);
            using GltfData data = new GlbFileParser(VrmPath).Parse();
            TextureDescriptor[] descriptors = new Vrm10TextureDescriptorGenerator(data)
                .Get().GetEnumerable().ToArray();
            if (!descriptors.Any(d => d.TextureType == TextureImportTypes.NormalMap))
                throw new InvalidOperationException("Joy has no normal textures to preserve.");

            AssetDatabase.ImportAsset(VrmPath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            AssetImporter vrmImporter = AssetImporter.GetAtPath(VrmPath);
            if (vrmImporter == null) throw new InvalidOperationException("Joy has no VRM importer.");

            // Always re-extract from unconverted embedded pixels. Exporting an already
            // platform-encoded normal asset to PNG would apply encoding a second time.
            var textureRemaps = vrmImporter.GetExternalObjectMap()
                .Where(pair => typeof(Texture).IsAssignableFrom(pair.Key.type)).ToArray();
            foreach (var remap in textureRemaps)
            {
                string path = AssetDatabase.GetAssetPath(remap.Value);
                if (remap.Value != null && !IsOwnedTexturePath(path))
                    throw new InvalidOperationException("Joy has a texture override outside the generated directory; preserving it: " + path);
            }
            foreach (var remap in textureRemaps) vrmImporter.RemoveRemap(remap.Key);
            AssetDatabase.WriteImportSettingsIfDirty(VrmPath);
            AssetDatabase.ImportAsset(VrmPath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);

            Dictionary<SubAssetKey, Texture> embedded = AssetDatabase.LoadAllAssetsAtPath(VrmPath)
                .OfType<Texture>().ToDictionary(texture => new SubAssetKey(texture));
            // The public UniGLTF extractor preserves converted Standard metallic/smoothness
            // maps as well as raw RGB normals. Use its instance API synchronously so a
            // command-line -quit cannot skip the convenience API's delayCall remaps.
            var extractor = new TextureExtractor(data, UnityPath.FromUnityPath(TextureDirectory), embedded);
            foreach (TextureDescriptor descriptor in descriptors)
            {
                if (descriptor.UnityObjectName != Path.GetFileName(descriptor.UnityObjectName))
                    throw new InvalidOperationException("Unsafe texture name in Joy: " + descriptor.UnityObjectName);
                extractor.Extract(descriptor.SubAssetKey, descriptor);
            }
            if (extractor.Textures.Count != descriptors.Length)
                throw new InvalidOperationException("Not every Joy descriptor was extracted; no partial remap will be applied.");

            var prepared = new Dictionary<SubAssetKey, Texture2D>();
            foreach (TextureDescriptor descriptor in descriptors)
            {
                string path = extractor.Textures[descriptor.SubAssetKey].Value;
                AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceSynchronousImport);
                if (AssetImporter.GetAtPath(path) is not TextureImporter textureImporter)
                    throw new InvalidOperationException("Extracted texture has no native importer: " + path);
                ApplyTextureSettings(textureImporter, descriptor);
                textureImporter.SaveAndReimport();
                Texture2D texture = AssetDatabase.LoadAssetAtPath<Texture2D>(path);
                if (texture == null) throw new InvalidOperationException("Extracted texture did not import: " + path);
                prepared.Add(descriptor.SubAssetKey, texture);
            }

            vrmImporter = AssetImporter.GetAtPath(VrmPath);
            foreach (var pair in prepared)
                vrmImporter.AddRemap(new AssetImporter.SourceAssetIdentifier(pair.Key.Type, pair.Key.Name), pair.Value);
            AssetDatabase.WriteImportSettingsIfDirty(VrmPath);
            AssetDatabase.ImportAsset(VrmPath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            AssetDatabase.SaveAssets();

            int normalBindings = ValidateImportedPrefab(descriptors);
            bool unchanged = sourceHash == Sha256(VrmPath);
            if (!unchanged) throw new InvalidOperationException("Joy source bytes changed during texture preparation.");
            return new ImportReport
            {
                vrmPath = VrmPath,
                vrmSha256 = sourceHash,
                activeBuildTarget = EditorUserBuildSettings.activeBuildTarget.ToString(),
                sourceVrmUnchanged = unchanged,
                importedPrefabValidated = true,
                runtimeExternalVrmCovered = false,
                normalTextureCount = descriptors.Count(d => d.TextureType == TextureImportTypes.NormalMap),
                materialNormalBindingCount = normalBindings,
                textures = descriptors.Select(d =>
                {
                    Texture2D texture = prepared[d.SubAssetKey];
                    return new TextureReport
                    {
                        name = d.UnityObjectName, assetPath = AssetDatabase.GetAssetPath(texture),
                        role = d.TextureType.ToString(), width = texture.width, height = texture.height,
                        activeFormat = texture.format.ToString()
                    };
                }).ToArray()
            };
        }

        public static bool IsOwnedTexturePath(string path) =>
            !string.IsNullOrEmpty(path) && path.StartsWith(TextureDirectory + "/", StringComparison.Ordinal);

        /// <summary>Preserve glTF roles/samplers; native normal import owns platform channel packing.</summary>
        public static void ApplyTextureSettings(TextureImporter importer, TextureDescriptor descriptor)
        {
            if (importer == null) throw new ArgumentNullException(nameof(importer));
            importer.GetSourceTextureWidthAndHeight(out int width, out int height);
            int sourceLimit = Mathf.NextPowerOfTwo(Mathf.Max(width, height));
            if (sourceLimit < 1 || sourceLimit > 16384)
                throw new InvalidOperationException("Unsupported Joy texture dimensions: " + importer.assetPath);
            sourceLimit = Mathf.Max(32, sourceLimit);
            importer.textureType = descriptor.TextureType == TextureImportTypes.NormalMap
                ? TextureImporterType.NormalMap : TextureImporterType.Default;
            importer.sRGBTexture = descriptor.TextureType == TextureImportTypes.sRGB;
            importer.convertToNormalmap = false;
            importer.flipGreenChannel = false;
            importer.alphaIsTransparency = false;
            importer.npotScale = TextureImporterNPOTScale.None;
            importer.maxTextureSize = sourceLimit;
            importer.mipmapEnabled = descriptor.Sampler.EnableMipMap;
            importer.filterMode = descriptor.Sampler.FilterMode;
            importer.wrapModeU = descriptor.Sampler.WrapModesU;
            importer.wrapModeV = descriptor.Sampler.WrapModesV;
            importer.anisoLevel = 8;
            // Match the existing desktop fidelity policy without changing other avatars.
            SetPlatform(importer, "Standalone", sourceLimit, TextureImporterFormat.RGBA32,
                TextureImporterCompression.Uncompressed);
            SetPlatform(importer, "iPhone", MobileTextureLimit, TextureImporterFormat.ASTC_4x4,
                TextureImporterCompression.CompressedHQ);
            SetPlatform(importer, "Android", MobileTextureLimit, TextureImporterFormat.ASTC_4x4,
                TextureImporterCompression.CompressedHQ);
        }

        private static void SetPlatform(TextureImporter importer, string platform, int limit,
            TextureImporterFormat format, TextureImporterCompression compression)
        {
            TextureImporterPlatformSettings settings = importer.GetPlatformTextureSettings(platform);
            settings.name = platform;
            settings.overridden = true;
            settings.maxTextureSize = limit;
            settings.format = format;
            settings.textureCompression = compression;
            settings.crunchedCompression = false;
            settings.compressionQuality = 100;
            importer.SetPlatformTextureSettings(settings);
        }

        private static int ValidateImportedPrefab(TextureDescriptor[] descriptors)
        {
            var map = AssetImporter.GetAtPath(VrmPath).GetExternalObjectMap();
            var normalAssets = new HashSet<Texture>();
            foreach (TextureDescriptor descriptor in descriptors)
            {
                var key = new AssetImporter.SourceAssetIdentifier(descriptor.SubAssetKey.Type, descriptor.SubAssetKey.Name);
                if (!map.TryGetValue(key, out UnityEngine.Object value) || value is not Texture2D texture)
                    throw new InvalidOperationException("Joy texture remap is missing: " + descriptor.UnityObjectName);
                string path = AssetDatabase.GetAssetPath(texture);
                if (!IsOwnedTexturePath(path) || AssetImporter.GetAtPath(path) is not TextureImporter importer)
                    throw new InvalidOperationException("Joy texture still bypasses the native importer: " + path);
                if (descriptor.TextureType == TextureImportTypes.NormalMap)
                {
                    if (importer.textureType != TextureImporterType.NormalMap || importer.sRGBTexture)
                        throw new InvalidOperationException("Joy normal texture has the wrong type/color space: " + path);
                    normalAssets.Add(texture);
                }
            }
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(VrmPath);
            if (prefab == null) throw new InvalidOperationException("Joy prefab is missing after remapping.");
            Material[] materials = prefab.GetComponentsInChildren<Renderer>(true)
                .SelectMany(renderer => renderer.sharedMaterials).Where(material => material != null).Distinct().ToArray();
            int bindings = 0;
            foreach (Material material in materials)
            {
                if (!material.HasProperty("_BumpMap") || material.GetTexture("_BumpMap") == null) continue;
                if (!normalAssets.Contains(material.GetTexture("_BumpMap")))
                    throw new InvalidOperationException("Material still uses an embedded/unprepared normal: " + material.name);
                bindings++;
            }
            if (bindings == 0) throw new InvalidOperationException("Imported Joy materials lost all normal map bindings.");
            return bindings;
        }

        private static string Sha256(string path)
        {
            using SHA256 hash = SHA256.Create();
            using FileStream stream = File.OpenRead(path);
            return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
    }
}
