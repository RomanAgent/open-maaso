using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class MaasoModularAnimePreviewCapture
    {
        public static void Capture()
        {
            CaptureAvatar(
                "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Female.prefab",
                "/tmp/maaso-modular-anime-female.png");
        }

        private static void CaptureAvatar(
            string prefabAssetPath,
            string outputPath)
        {
            GameObject prefab =
                AssetDatabase.LoadAssetAtPath<GameObject>(prefabAssetPath);
            if (prefab == null)
            {
                throw new InvalidOperationException(
                    "Preview prefab is missing: " + prefabAssetPath);
            }

            GameObject avatar = UnityEngine.Object.Instantiate(prefab);
            GameObject cameraObject = new GameObject("Preview Camera");
            GameObject lightObject = new GameObject("Preview Light");
            RenderTexture target = null;
            Texture2D capture = null;
            try
            {
                avatar.transform.SetPositionAndRotation(
                    Vector3.zero,
                    Quaternion.identity);
                Animator[] animators =
                    avatar.GetComponentsInChildren<Animator>(true);
                for (int index = 0; index < animators.Length; index++)
                {
                    AnimationClip idle = animators[index]
                        .runtimeAnimatorController
                        ?.animationClips
                        .FirstOrDefault(clip => clip.name == "idle_shrug");
                    if (idle != null)
                    {
                        idle.SampleAnimation(avatar, 0f);
                    }
                    animators[index].enabled = false;
                }
                LogKeyRenderers(avatar);
                Bounds bounds = VisualBounds(avatar);

                Camera camera = cameraObject.AddComponent<Camera>();
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(0.74f, 0.88f, 1f, 1f);
                camera.fieldOfView = 28f;
                camera.aspect = 2f / 3f;
                camera.nearClipPlane = 0.01f;
                camera.farClipPlane = 100f;
                float halfFov =
                    camera.fieldOfView * Mathf.Deg2Rad * 0.5f;
                float verticalDistance =
                    bounds.extents.y / Mathf.Tan(halfFov);
                float horizontalDistance =
                    bounds.extents.x /
                    (Mathf.Tan(halfFov) * camera.aspect);
                float distance = Mathf.Max(
                    Mathf.Max(verticalDistance, horizontalDistance) * 1.12f,
                    2f);
                cameraObject.transform.position =
                    bounds.center + Vector3.forward * distance;
                cameraObject.transform.LookAt(bounds.center);

                Light light = lightObject.AddComponent<Light>();
                light.type = LightType.Directional;
                light.intensity = 1.1f;
                light.color = new Color(1f, 0.96f, 0.9f);
                lightObject.transform.rotation =
                    Quaternion.Euler(35f, 150f, 0f);
                RenderSettings.ambientMode =
                    UnityEngine.Rendering.AmbientMode.Flat;
                RenderSettings.ambientLight =
                    new Color(0.42f, 0.46f, 0.52f);

                target = new RenderTexture(512, 768, 24);
                camera.targetTexture = target;
                camera.Render();
                RenderTexture previous = RenderTexture.active;
                RenderTexture.active = target;
                capture = new Texture2D(
                    target.width,
                    target.height,
                    TextureFormat.RGB24,
                    false);
                capture.ReadPixels(
                    new Rect(0, 0, target.width, target.height),
                    0,
                    0);
                capture.Apply();
                File.WriteAllBytes(outputPath, capture.EncodeToPNG());
                RenderTexture.active = previous;
                Debug.Log("[MaasoAvatar] Wrote preview " + outputPath);
            }
            finally
            {
                if (capture != null)
                {
                    UnityEngine.Object.DestroyImmediate(capture);
                }
                if (target != null)
                {
                    UnityEngine.Object.DestroyImmediate(target);
                }
                UnityEngine.Object.DestroyImmediate(lightObject);
                UnityEngine.Object.DestroyImmediate(cameraObject);
                UnityEngine.Object.DestroyImmediate(avatar);
            }
        }

        private static void LogKeyRenderers(GameObject avatar)
        {
            SkinnedMeshRenderer[] renderers =
                avatar.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            for (int index = 0; index < renderers.Length; index++)
            {
                SkinnedMeshRenderer renderer = renderers[index];
                if (!renderer.name.Contains("Head") &&
                    !renderer.name.Contains("hair") &&
                    renderer.name != "Top10" &&
                    renderer.name != "Bot4" &&
                    renderer.name != "Shoes6")
                {
                    continue;
                }

                Mesh baked = new Mesh();
                renderer.BakeMesh(baked);
                try
                {
                    Debug.Log(
                        "[MaasoAvatar] Preview renderer " +
                        renderer.name +
                        " active=" + renderer.gameObject.activeInHierarchy +
                        " enabled=" + renderer.enabled +
                        " verts=" +
                        (renderer.sharedMesh == null
                            ? 0
                            : renderer.sharedMesh.vertexCount) +
                        " submeshes=" +
                        (renderer.sharedMesh == null
                            ? 0
                            : renderer.sharedMesh.subMeshCount) +
                        " materials=" + renderer.sharedMaterials.Length +
                        " bounds=" + renderer.bounds +
                        " bakedBounds=" + baked.bounds);
                }
                finally
                {
                    UnityEngine.Object.DestroyImmediate(baked);
                }
            }
        }

        private static Bounds VisualBounds(GameObject avatar)
        {
            Renderer[] renderers =
                avatar.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length == 0)
            {
                throw new InvalidOperationException(
                    "Preview avatar has no renderers: " + avatar.name);
            }

            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }
    }
}
