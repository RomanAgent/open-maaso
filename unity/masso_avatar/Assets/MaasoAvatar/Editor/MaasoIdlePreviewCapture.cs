#if UNITY_EDITOR
using System;
using System.IO;
using System.Reflection;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class MaasoIdlePreviewCapture
    {
        private const string ScenePath =
            MaasoDefaultAvatarSceneBuilder.ScenePath;
        private const string OutputDirectory = "Builds/Preview";
        private const int Width = 900;
        private const int Height = 1200;
        private const int BackgroundTolerance = 12;

        [MenuItem("Maaso/Actions/Capture Main Idle Preview", false, 20)]
        public static void CaptureIdlePreview()
        {
            EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);

            Camera camera = Camera.main;
            if (camera == null)
            {
                throw new InvalidOperationException("Main Camera not found.");
            }

            var receiver = UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
            if (receiver == null)
            {
                throw new InvalidOperationException("UnityAvatarCommandReceiver not found.");
            }

            Directory.CreateDirectory(OutputDirectory);
            DeleteStaleProceduralPreview("maaso_idle_phase0.png");
            DeleteStaleProceduralPreview("maaso_idle_phase1.png");
            DeleteStaleProceduralPreview("maaso_idle_phase2.png");
            CaptureDesignedIdle(camera, receiver, "maaso_idle_designed.png");
            AssetDatabase.Refresh();
        }

        private static void CaptureDesignedIdle(
            Camera camera,
            UnityAvatarCommandReceiver receiver,
            string fileName)
        {
            InvokeReceiverMethod(receiver, "EnsureAvatar");
            MethodInfo tryStartDesignedIdle = typeof(UnityAvatarCommandReceiver).GetMethod(
                "TryStartDesignedIdle",
                BindingFlags.NonPublic | BindingFlags.Instance,
                null,
                Type.EmptyTypes,
                null);
            if (tryStartDesignedIdle == null)
            {
                throw new MissingMethodException(nameof(UnityAvatarCommandReceiver), "TryStartDesignedIdle");
            }

            bool hasDesignedIdle = (bool)tryStartDesignedIdle.Invoke(receiver, Array.Empty<object>());
            if (!hasDesignedIdle)
            {
                Debug.LogWarning("[MaasoIdlePreview] No designed Animator/VRC Idle state found. Preview will show the current bind pose.");
            }
            else
            {
                SampleIdleFrame(receiver);
                InvokeReceiverMethod(receiver, "LateUpdate");
            }

            RenderTexture previousTarget = camera.targetTexture;
            CameraClearFlags previousClearFlags = camera.clearFlags;
            Color previousBackground = camera.backgroundColor;
            RenderTexture renderTexture = new(Width, Height, 24, RenderTextureFormat.ARGB32);
            Texture2D image = new(Width, Height, TextureFormat.RGBA32, false);

            try
            {
                camera.targetTexture = renderTexture;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(0.96f, 0.95f, 0.93f, 1f);

                FrontFullBodyCamera framing = camera.GetComponent<FrontFullBodyCamera>();
                ApplyPreviewSafeArea(framing);
                LogRendererViewportBounds(camera, framing);

                camera.Render();
                RenderTexture.active = renderTexture;
                image.ReadPixels(new Rect(0, 0, Width, Height), 0, 0);
                image.Apply();
                LogRenderedPixelBounds(image);

                File.WriteAllBytes(
                    Path.Combine(OutputDirectory, fileName),
                    image.EncodeToPNG());
            }
            finally
            {
                camera.targetTexture = previousTarget;
                camera.clearFlags = previousClearFlags;
                camera.backgroundColor = previousBackground;
                RenderTexture.active = null;
                UnityEngine.Object.DestroyImmediate(image);
                UnityEngine.Object.DestroyImmediate(renderTexture);
            }
        }

        private static void SampleIdleFrame(UnityAvatarCommandReceiver receiver)
        {
            FieldInfo animatorField = typeof(UnityAvatarCommandReceiver).GetField(
                "animator",
                BindingFlags.NonPublic | BindingFlags.Instance);
            FieldInfo idleNameField = typeof(UnityAvatarCommandReceiver).GetField(
                "designedIdleStateName",
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (animatorField == null)
            {
                throw new MissingFieldException(nameof(UnityAvatarCommandReceiver), "animator");
            }

            var animator = animatorField.GetValue(receiver) as Animator;
            if (animator == null || animator.runtimeAnimatorController == null)
            {
                return;
            }

            string stateName = idleNameField?.GetValue(receiver) as string;
            if (string.IsNullOrWhiteSpace(stateName))
            {
                stateName = "Idle";
            }

            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.Rebind();
            int stateHash = Animator.StringToHash(stateName);
            for (int layer = 0; layer < animator.layerCount; layer++)
            {
                if (animator.HasState(layer, stateHash))
                {
                    animator.Play(stateHash, layer, 0.5f);
                }
            }

            animator.Update(1f / 60f);
        }

        private static void InvokeReceiverMethod(UnityAvatarCommandReceiver receiver, string methodName)
        {
            MethodInfo method = typeof(UnityAvatarCommandReceiver).GetMethod(
                methodName,
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (method == null)
            {
                throw new MissingMethodException(nameof(UnityAvatarCommandReceiver), methodName);
            }

            method.Invoke(receiver, Array.Empty<object>());
        }

        private static void DeleteStaleProceduralPreview(string fileName)
        {
            string path = Path.Combine(OutputDirectory, fileName);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }

        private static void ApplyPreviewSafeArea(FrontFullBodyCamera framing)
        {
            if (framing == null)
            {
                return;
            }

            float top = ResolveFloatArgument("-previewTopSafe", float.NaN);
            float bottom = ResolveFloatArgument("-previewBottomSafe", float.NaN);
            if (float.IsNaN(top) && float.IsNaN(bottom))
            {
                framing.FrameNow();
                return;
            }

            framing.SetViewportSafeArea(
                float.IsNaN(top) ? 0f : top,
                float.IsNaN(bottom) ? 0f : bottom);
        }

        private static void LogRendererViewportBounds(Camera camera, FrontFullBodyCamera framing)
        {
            if (camera == null || framing == null || framing.TargetRoot == null)
            {
                return;
            }

            Renderer[] renderers = framing.TargetRoot.GetComponentsInChildren<Renderer>(false);
            bool hasPoint = false;
            float minX = float.PositiveInfinity;
            float minY = float.PositiveInfinity;
            float maxX = float.NegativeInfinity;
            float maxY = float.NegativeInfinity;

            for (int i = 0; i < renderers.Length; i++)
            {
                Renderer renderer = renderers[i];
                if (renderer == null || !renderer.enabled)
                {
                    continue;
                }

                Bounds bounds = renderer.bounds;
                Vector3 extents = bounds.extents;
                for (int x = -1; x <= 1; x += 2)
                {
                    for (int y = -1; y <= 1; y += 2)
                    {
                        for (int z = -1; z <= 1; z += 2)
                        {
                            Vector3 point = bounds.center + new Vector3(
                                extents.x * x,
                                extents.y * y,
                                extents.z * z);
                            Vector3 viewport = camera.WorldToViewportPoint(point);
                            minX = Mathf.Min(minX, viewport.x);
                            minY = Mathf.Min(minY, viewport.y);
                            maxX = Mathf.Max(maxX, viewport.x);
                            maxY = Mathf.Max(maxY, viewport.y);
                            hasPoint = true;
                        }
                    }
                }
            }

            if (!hasPoint)
            {
                return;
            }

            Debug.Log(
                $"[MaasoIdlePreview] renderer viewport bbox x={minX:F3}-{maxX:F3} y={minY:F3}-{maxY:F3}");
        }

        private static void LogRenderedPixelBounds(Texture2D image)
        {
            Color32[] pixels = image.GetPixels32();
            if (pixels.Length == 0)
            {
                return;
            }

            Color32 background = pixels[0];
            int minX = image.width;
            int minY = image.height;
            int maxX = -1;
            int maxY = -1;

            for (int y = 0; y < image.height; y++)
            {
                for (int x = 0; x < image.width; x++)
                {
                    Color32 pixel = pixels[(y * image.width) + x];
                    if (Mathf.Abs(pixel.r - background.r) <= BackgroundTolerance &&
                        Mathf.Abs(pixel.g - background.g) <= BackgroundTolerance &&
                        Mathf.Abs(pixel.b - background.b) <= BackgroundTolerance)
                    {
                        continue;
                    }

                    minX = Mathf.Min(minX, x);
                    minY = Mathf.Min(minY, y);
                    maxX = Mathf.Max(maxX, x);
                    maxY = Mathf.Max(maxY, y);
                }
            }

            if (maxX < minX || maxY < minY)
            {
                Debug.Log("[MaasoIdlePreview] rendered pixel bbox empty");
                return;
            }

            Debug.Log(
                "[MaasoIdlePreview] rendered pixel bbox " +
                $"x={(float)minX / image.width:F3}-{(float)(maxX + 1) / image.width:F3} " +
                $"y={(float)minY / image.height:F3}-{(float)(maxY + 1) / image.height:F3}");
        }

        private static float ResolveFloatArgument(string name, float fallback)
        {
            string[] arguments = Environment.GetCommandLineArgs();
            for (int i = 0; i < arguments.Length - 1; i++)
            {
                if (!string.Equals(arguments[i], name, StringComparison.Ordinal))
                {
                    continue;
                }

                return float.TryParse(arguments[i + 1], out float value) ? value : fallback;
            }

            return fallback;
        }
    }
}
#endif
