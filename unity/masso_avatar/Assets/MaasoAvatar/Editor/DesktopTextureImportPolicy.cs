using System;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>Keep authored pixels in desktop builds without changing mobile imports.</summary>
    public sealed class DesktopTextureImportPolicy : IPreprocessBuildWithReport
    {
        public int callbackOrder => -100;

        public void OnPreprocessBuild(BuildReport report)
        {
            if (BuildPipeline.GetBuildTargetGroup(report.summary.platform) == BuildTargetGroup.Standalone)
                ApplyStandaloneTextures();
        }

        [MenuItem("Maaso/Avatar/Apply Desktop Texture Fidelity")]
        public static void ApplyStandaloneTextures()
        {
            int changed = 0;
            foreach (string guid in AssetDatabase.FindAssets("t:Texture2D",
                new[] { "Assets/MaasoAvatar", "Assets/MaasoWorld" }))
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (AssetImporter.GetAtPath(path) is not TextureImporter importer) continue;
                if (!ConfigureStandalone(importer)) continue;
                importer.SaveAndReimport();
                changed++;
            }
            Debug.Log($"[DesktopTextureQuality] Preserved source resolution and uncompressed pixels for {changed} texture imports; mobile overrides unchanged.");
        }

        public static bool ConfigureStandalone(TextureImporter importer)
        {
            if (importer == null) throw new ArgumentNullException(nameof(importer));
            importer.GetSourceTextureWidthAndHeight(out int width, out int height);
            int sourceLimit = Mathf.NextPowerOfTwo(Mathf.Max(width, height));
            if (sourceLimit <= 0 || sourceLimit > 16384)
                throw new BuildFailedException("Unsupported source texture dimensions: " + importer.assetPath);
            TextureImporterPlatformSettings settings = importer.GetPlatformTextureSettings("Standalone");
            string before = JsonUtility.ToJson(settings);
            settings.name = "Standalone";
            settings.overridden = true;
            // maxTextureSize is a ceiling, not a resize target. Smaller sources
            // retain their original pixels, including the 1672x941 ocean image.
            settings.maxTextureSize = Math.Max(32, sourceLimit);
            settings.format = TextureImporterFormat.RGBA32;
            settings.textureCompression = TextureImporterCompression.Uncompressed;
            settings.crunchedCompression = false;
            settings.compressionQuality = 100;
            if (JsonUtility.ToJson(settings) == before) return false;
            importer.SetPlatformTextureSettings(settings);
            return true;
        }
    }
}
