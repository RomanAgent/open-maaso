using System.Threading;
using System.Threading.Tasks;
using UniGLTF;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    /// <summary>
    /// Keeps UniGLTF's non-auto-referenced await types behind a stable Maaso API.
    /// </summary>
    public static class MaasoVrmLoader
    {
        public static async Task<Vrm10Instance> LoadVrm10Async(
            string path,
            CancellationToken cancellationToken = default)
        {
            Vrm10Instance instance = await Vrm10.LoadPathAsync(
                path,
                canLoadVrm0X: false,
                showMeshes: true,
                awaitCaller: CreateAwaitCaller(
                    Application.platform,
                    Application.isPlaying),
                ct: cancellationToken);
            if (instance != null)
                DesktopTextureQuality.ApplyAvatarTextures(instance.gameObject, Application.platform);
            return instance;
        }

        private static IAwaitCaller CreateAwaitCaller(
            RuntimePlatform platform,
            bool isPlaying)
        {
            if (!isPlaying)
            {
                return new ImmediateCaller();
            }

            return platform == RuntimePlatform.WebGLPlayer
                ? new RuntimeOnlyNoThreadAwaitCaller()
                : new RuntimeOnlyAwaitCaller();
        }
    }
}
