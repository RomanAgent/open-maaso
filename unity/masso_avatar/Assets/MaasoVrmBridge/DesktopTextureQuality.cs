using System.Collections.Generic;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Maaso.Avatar
{
    /// <summary>Sampling quality only; never synthesizes detail or copies texture pixels.</summary>
    public static class DesktopTextureQuality
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        private static void Bootstrap()
        {
            ApplyRuntimeQuality(Application.platform);
            if (!IsDesktopPlayer(Application.platform)) return;
            SceneManager.sceneLoaded -= ApplySceneTextures;
            SceneManager.sceneLoaded += ApplySceneTextures;
        }

        private static void ApplySceneTextures(Scene scene, LoadSceneMode mode)
        {
            foreach (GameObject root in scene.GetRootGameObjects())
                ApplyAvatarTextures(root, Application.platform);
        }

        public static bool IsDesktopPlayer(RuntimePlatform platform) =>
            platform == RuntimePlatform.OSXPlayer ||
            platform == RuntimePlatform.WindowsPlayer ||
            platform == RuntimePlatform.LinuxPlayer;

        public static void ApplyRuntimeQuality(RuntimePlatform platform)
        {
            if (!IsDesktopPlayer(platform)) return;
            QualitySettings.globalTextureMipmapLimit = 0;
            QualitySettings.anisotropicFiltering = AnisotropicFiltering.ForceEnable;
            Texture.SetGlobalAnisotropicFilteringLimits(16, 16);
        }

        public static void ApplyAvatarTextures(GameObject root, RuntimePlatform platform)
        {
            if (root == null || !IsDesktopPlayer(platform)) return;
            var seen = new HashSet<Texture>();
            foreach (Renderer renderer in root.GetComponentsInChildren<Renderer>(true))
            foreach (Material material in renderer.sharedMaterials)
            {
                if (material == null) continue;
                foreach (int property in material.GetTexturePropertyNameIDs())
                {
                    if (material.GetTexture(property) is not Texture2D texture || !seen.Add(texture)) continue;
                    texture.filterMode = texture.mipmapCount > 1 ? FilterMode.Trilinear : FilterMode.Bilinear;
                    texture.anisoLevel = 16;
                }
            }
        }
    }
}
