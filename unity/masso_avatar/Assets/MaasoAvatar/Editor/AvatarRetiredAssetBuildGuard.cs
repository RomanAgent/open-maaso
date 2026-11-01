#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>Checks actual player-pack contents, including incremental exports.</summary>
    public sealed class AvatarRetiredAssetBuildGuard : IPostprocessBuildWithReport
    {
        private const string JoySourcePath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const string MattSourceDirectory = "Assets/MaasoAvatar/Models/Matt/";
        private const string LegacyMaleMaterials = "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Materials/Male/";
        private static readonly HashSet<string> RetiredSourceFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Assets/MaasoAvatar/Resources/MaleCompanion.prefab",
            "Assets/MaasoAvatar/Resources/MattIdentity.json",
            "Assets/MaasoAvatar/Resources/MattPupilStandard.shader",
            "Assets/MaasoAvatar/Resources/MattPupilUv.cginc",
            "Assets/MaasoAvatar/Shaders/MattTwoSidedCutout.shader",
            "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Male.prefab",
            "Assets/Rukha93/ModularAnimeCharacter/Prefabs/M_FullBody.prefab",
            "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/M_top.010_shirtandtie.fbx",
            "Assets/Rukha93/ModularAnimeCharacter/Assets/Meshes/M_bot.004_skinnyjeans.fbx",
        };

        public int callbackOrder { get { return int.MaxValue; } }

        public void OnPostprocessBuild(BuildReport report)
        {
            if (report == null) throw new BuildFailedException("Avatar asset audit requires the completed player build report.");
            var packed = report.packedAssets;
            var sourcePaths = packed == null ? Enumerable.Empty<string>() :
                packed.SelectMany(asset => asset.contents ?? Array.Empty<PackedAssetInfo>())
                    .Select(asset => asset.sourceAssetPath);
            Audit audit = CreateAudit(sourcePaths, report.summary.platform.ToString(), report.summary.guid.ToString());
            string output = Environment.GetEnvironmentVariable("MAASO_AVATAR_ASSET_AUDIT_PATH");
            if (!string.IsNullOrWhiteSpace(output))
            {
                try
                {
                    string path = Path.GetFullPath(output);
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    File.WriteAllText(path, JsonUtility.ToJson(audit, true) + "\n", new UTF8Encoding(false));
                }
                catch (Exception error)
                {
                    throw new BuildFailedException("Could not write the requested Avatar packed-asset audit: " + error.Message);
                }
            }
            RequireAllowed(audit);
            Debug.Log("[MaasoAvatarAssetAudit] target=" + audit.target + " build=" + audit.buildGuid +
                " sourcePaths=" + audit.sourcePathCount + " retired=" + audit.retiredSourceCount +
                " joy=" + audit.retainedJoySourceFound + " pathListSha256=" + audit.sourcePathListSha256);
        }

        internal static bool IsRetiredSourcePath(string sourcePath)
        {
            string path = Normalize(sourcePath);
            return path.StartsWith(MattSourceDirectory, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(LegacyMaleMaterials, StringComparison.OrdinalIgnoreCase) ||
                RetiredSourceFiles.Contains(path);
        }

        internal static Audit CreateAudit(IEnumerable<string> sourcePaths, string target, string buildGuid)
        {
            string[] paths = (sourcePaths ?? Enumerable.Empty<string>()).Select(Normalize)
                .Where(path => path.Length != 0).Distinct(StringComparer.Ordinal)
                .OrderBy(path => path, StringComparer.Ordinal).ToArray();
            string[] retired = paths.Where(IsRetiredSourcePath).ToArray();
            string[] joy = paths.Where(path => string.Equals(path, JoySourcePath, StringComparison.OrdinalIgnoreCase)).ToArray();
            string canonical = paths.Length == 0 ? string.Empty : string.Join("\n", paths) + "\n";
            string digest;
            using (var hash = SHA256.Create())
            {
                var text = new StringBuilder(64);
                foreach (byte value in hash.ComputeHash(Encoding.UTF8.GetBytes(canonical))) text.Append(value.ToString("x2"));
                digest = text.ToString();
            }
            return new Audit
            {
                target = target,
                buildGuid = buildGuid,
                sourcePathCount = paths.Length,
                sourcePathListSha256 = digest,
                retiredSourceCount = retired.Length,
                retiredSourcePaths = retired,
                retainedJoySourceFound = joy.Length > 0,
                retainedJoyEvidencePaths = joy,
            };
        }

        internal static void RequireAllowed(Audit audit)
        {
            if (audit.retiredSourceCount != 0)
                throw new BuildFailedException("Retired official Avatar assets entered the player pack: " +
                    string.Join(", ", audit.retiredSourcePaths.Take(8).ToArray()));
            // Empty or partial evidence cannot prove that a reused export is
            // clean. Maaso player exports must still contain the retained Joy.
            if (audit.sourcePathCount == 0 || !audit.retainedJoySourceFound)
                throw new BuildFailedException("Avatar packed-asset report is incomplete: the retained Joy source was not found.");
        }

        private static string Normalize(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return string.Empty;
            string normalized = path.Replace('\\', '/');
            while (normalized.StartsWith("./", StringComparison.Ordinal)) normalized = normalized.Substring(2);
            return normalized;
        }

        [Serializable]
        public sealed class Audit
        {
            public int schemaVersion = 1;
            public string target;
            public string buildGuid;
            public int sourcePathCount;
            public string sourcePathListCanonicalization = "ordinal-sorted-distinct-project-paths-utf8-lf-v1";
            public string sourcePathListSha256;
            public int retiredSourceCount;
            public string[] retiredSourcePaths;
            public bool retainedJoySourceFound;
            public string[] retainedJoyEvidencePaths;
        }
    }
}
#endif
