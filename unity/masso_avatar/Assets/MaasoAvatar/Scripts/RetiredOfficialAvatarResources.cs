using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>Exact retired product identities and their formerly published cache files.</summary>
    internal static class RetiredOfficialAvatarResources
    {
        // Historical official Modular Male bundles, read from the publication
        // inventory. Never derive a deletion target from an incoming descriptor.
        private static readonly string[] PublishedBundleHashes =
        {
            "bf02cc5e4e83a2eb8eacf6e67d60f58f1e78b86a41a02259e0ed10bbbe50e627",
            "e8e0a4a4517c89d7f5cb6747f9523d875916857d7e0d9e05cfe7e125abbc85e9",
            "7dadce10eb4a1a35f83d9be7a930d42ba2ba9b414077d0b966deccd4d0704157",
            "c7d0503eec0ccb1c88081106e9115e863e54fa80d996179d8153a66f0cb5c402",
        };
        private static bool cacheChecked;

        internal static bool IsRetiredDescriptor(string modelKey, string modelUrl)
        {
            return string.Equals(modelUrl, "unity://masso/avatar_matt", StringComparison.OrdinalIgnoreCase) ||
                modelKey == "masso.bundled.matt" || modelKey == "modular-anime-male" ||
                modelKey == "masso.official.modular-male";
        }

        internal static void PurgeLegacyCache()
        {
            if (cacheChecked) return;
            try
            {
                PurgeVerifiedCache(Path.Combine(Application.persistentDataPath, "MaasoAvatarBundles"), PublishedBundleHashes);
                cacheChecked = true;
            }
            catch (IOException) { /* A later load can retry a temporarily busy cache. */ }
            catch (UnauthorizedAccessException) { /* Keep other application data untouched. */ }
        }

        internal static int PurgeVerifiedCache(string directory, string[] hashes)
        {
            if (!Directory.Exists(directory) ||
                (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) return 0;
            int removed = 0;
            foreach (string digest in hashes)
            {
                if (digest == null || digest.Length != 64) continue;
                bool valid = true;
                foreach (char digit in digest)
                    valid &= digit >= '0' && digit <= '9' || digit >= 'a' && digit <= 'f';
                if (!valid) continue;
                string candidate = Path.Combine(directory, digest + ".bundle");
                if (!File.Exists(candidate) ||
                    (File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0) continue;
                string actual;
                using (var stream = File.OpenRead(candidate))
                using (var hash = SHA256.Create())
                {
                    var text = new StringBuilder(64);
                    foreach (byte value in hash.ComputeHash(stream)) text.Append(value.ToString("x2"));
                    actual = text.ToString();
                }
                if (actual != digest) continue;
                File.Delete(candidate);
                removed++;
            }
            return removed;
        }
    }
}
