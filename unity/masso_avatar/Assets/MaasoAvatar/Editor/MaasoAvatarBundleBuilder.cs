#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Avatar.Editor
{
    public static class MaasoAvatarBundleBuilder
    {
        private const string BundleVersion = "1";
        private const string DefaultOutputRoot = "Builds/AvatarBundles/v1";
        private const string FemalePrefabPath =
            "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Female.prefab";

        private static readonly AvatarDefinition[] Avatars =
        {
            new AvatarDefinition(
                "modular-anime-female",
                "Modular Anime Female",
                FemalePrefabPath,
                "Female"),
        };

        [MenuItem("Maaso/Build Official Avatar Bundles/All Platforms")]
        public static void BuildAll()
        {
            string outputRoot = ResolveOutputRoot();
            ValidateApprovedPrefabs();
            var reports = new List<AvatarBundleReport>();
            BuildPlatform(
                outputRoot,
                BuildTarget.iOS,
                "ios",
                reports);
            BuildPlatform(
                outputRoot,
                BuildTarget.Android,
                "android",
                reports);

            var manifest = new AvatarBundleReleaseManifest
            {
                schemaVersion = 1,
                bundleVersion = BundleVersion,
                unityVersion = Application.unityVersion,
                renderPipeline = ResolveRenderPipeline(),
                generatedAtUtc = DateTime.UtcNow.ToString("O"),
                bundles = reports.ToArray(),
            };
            string manifestPath = Path.Combine(outputRoot, "release-manifest.json");
            File.WriteAllText(manifestPath, JsonUtility.ToJson(manifest, true));
            Debug.Log(
                "[MaasoAvatar] Built " + reports.Count +
                " platform bundles. Manifest: " + manifestPath);
        }

        private static string ResolveOutputRoot()
        {
            string configured =
                Environment.GetEnvironmentVariable("MAASO_AVATAR_BUNDLE_OUTPUT");
            string root = string.IsNullOrWhiteSpace(configured)
                ? Path.Combine(Directory.GetCurrentDirectory(), DefaultOutputRoot)
                : configured.Trim();
            root = Path.GetFullPath(root);
            string assetsRoot = Path.GetFullPath(Application.dataPath);
            if (root.StartsWith(
                    assetsRoot + Path.DirectorySeparatorChar,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "Avatar bundles must be built outside the Unity Assets directory.");
            }
            Directory.CreateDirectory(root);
            return root;
        }

        private static void ValidateApprovedPrefabs()
        {
            foreach (AvatarDefinition definition in Avatars)
            {
                GameObject prefab =
                    AssetDatabase.LoadAssetAtPath<GameObject>(definition.prefabPath);
                if (prefab == null)
                {
                    throw new FileNotFoundException(
                        "Approved avatar prefab is missing: " + definition.prefabPath);
                }

                Animator animator = prefab.GetComponentInChildren<Animator>(true);
                if (animator == null ||
                    animator.avatar == null ||
                    !animator.avatar.isHuman)
                {
                    throw new InvalidOperationException(
                        definition.modelKey + " is not configured as a Humanoid avatar.");
                }

                Renderer[] renderers = prefab.GetComponentsInChildren<Renderer>(true);
                if (renderers.Length == 0)
                {
                    throw new InvalidOperationException(
                        definition.modelKey + " has no renderers.");
                }

                bool hasMesh = false;
                foreach (Renderer renderer in renderers)
                {
                    if (renderer is SkinnedMeshRenderer skinned)
                    {
                        hasMesh |= skinned.sharedMesh != null &&
                            skinned.sharedMesh.vertexCount > 0;
                    }
                    else if (renderer is MeshRenderer)
                    {
                        MeshFilter filter = renderer.GetComponent<MeshFilter>();
                        hasMesh |= filter != null &&
                            filter.sharedMesh != null &&
                            filter.sharedMesh.vertexCount > 0;
                    }

                    Material[] materials = renderer.sharedMaterials;
                    if (materials == null || materials.Length == 0)
                    {
                        throw new InvalidOperationException(
                            definition.modelKey + " renderer has no material: " +
                            renderer.name);
                    }
                    foreach (Material material in materials)
                    {
                        if (material == null || material.shader == null)
                        {
                            throw new InvalidOperationException(
                                definition.modelKey +
                                " has a missing material or shader on renderer: " +
                                renderer.name);
                        }
                    }
                }

                if (!hasMesh)
                {
                    throw new InvalidOperationException(
                        definition.modelKey + " has no renderable mesh.");
                }
            }
        }

        private static void BuildPlatform(
            string outputRoot,
            BuildTarget target,
            string platform,
            List<AvatarBundleReport> reports)
        {
            string platformOutput = Path.Combine(outputRoot, platform);
            Directory.CreateDirectory(platformOutput);
            var buildMap = new AssetBundleBuild[Avatars.Length];
            for (int index = 0; index < Avatars.Length; index++)
            {
                AvatarDefinition definition = Avatars[index];
                string bundleFileName =
                    definition.modelKey + "-" + platform + ".bundle";
                DeleteIfExists(Path.Combine(platformOutput, bundleFileName));
                buildMap[index] = new AssetBundleBuild
                {
                    assetBundleName = bundleFileName,
                    assetNames = new[] { definition.prefabPath },
                    addressableNames = new[] { definition.assetName },
                };
            }

            BuildAssetBundleOptions options =
                BuildAssetBundleOptions.ChunkBasedCompression |
                BuildAssetBundleOptions.ForceRebuildAssetBundle |
                BuildAssetBundleOptions.StrictMode;
            AssetBundleManifest built = BuildPipeline.BuildAssetBundles(
                platformOutput,
                buildMap,
                options,
                target);
            if (built == null)
            {
                throw new InvalidOperationException(
                    "Unity returned no AssetBundle manifest for " + target + ".");
            }

            foreach (AvatarDefinition definition in Avatars)
            {
                string bundleFileName =
                    definition.modelKey + "-" + platform + ".bundle";
                string localPath = Path.Combine(platformOutput, bundleFileName);
                var file = new FileInfo(localPath);
                if (!file.Exists || file.Length <= 0)
                {
                    throw new InvalidOperationException(
                        "Expected avatar bundle was not built: " + localPath);
                }

                string sha256 = CalculateSha256(localPath);
                reports.Add(
                    new AvatarBundleReport
                    {
                        modelKey = definition.modelKey,
                        displayName = definition.displayName,
                        platform = platform,
                        localFile = platform + "/" + bundleFileName,
                        objectKey =
                            "avatar-models/official/" +
                            definition.modelKey +
                            "/v" +
                            BundleVersion +
                            "/" +
                            platform +
                            "/" +
                            sha256 +
                            ".bundle",
                        assetName = definition.assetName,
                        bundleVersion = BundleVersion,
                        unityVersion = Application.unityVersion,
                        buildTarget = target.ToString(),
                        assetBytes = file.Length,
                        assetSha256 = sha256,
                    });
            }
        }

        private static string CalculateSha256(string path)
        {
            using FileStream stream = File.OpenRead(path);
            using SHA256 sha256 = SHA256.Create();
            byte[] hash = sha256.ComputeHash(stream);
            return BitConverter
                .ToString(hash)
                .Replace("-", string.Empty)
                .ToLowerInvariant();
        }

        private static string ResolveRenderPipeline()
        {
            RenderPipelineAsset pipeline = GraphicsSettings.defaultRenderPipeline;
            return pipeline == null ? "builtin" : pipeline.GetType().FullName;
        }

        private static void DeleteIfExists(string path)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }

        private sealed class AvatarDefinition
        {
            public AvatarDefinition(
                string modelKey,
                string displayName,
                string prefabPath,
                string assetName)
            {
                this.modelKey = modelKey;
                this.displayName = displayName;
                this.prefabPath = prefabPath;
                this.assetName = assetName;
            }

            public readonly string modelKey;
            public readonly string displayName;
            public readonly string prefabPath;
            public readonly string assetName;
        }

        [Serializable]
        private sealed class AvatarBundleReleaseManifest
        {
            public int schemaVersion;
            public string bundleVersion;
            public string unityVersion;
            public string renderPipeline;
            public string generatedAtUtc;
            public AvatarBundleReport[] bundles;
        }

        [Serializable]
        private sealed class AvatarBundleReport
        {
            public string modelKey;
            public string displayName;
            public string platform;
            public string localFile;
            public string objectKey;
            public string assetName;
            public string bundleVersion;
            public string unityVersion;
            public string buildTarget;
            public long assetBytes;
            public string assetSha256;
        }
    }
}
#endif
