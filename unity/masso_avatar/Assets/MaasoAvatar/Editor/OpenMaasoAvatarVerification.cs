#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Maaso.Avatar;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class OpenMaasoAvatarVerification
    {
        private const string PreviewSession = "OpenMaaso.VerifyPlayMode";
        private static int previewFrames;
        private static double previewStart;

        public static void BeginPlayPreview()
        {
            MaasoDefaultAvatarSceneBuilder.RebuildScene();
            SessionState.SetBool(PreviewSession, true);
            EditorApplication.EnterPlaymode();
        }

        [InitializeOnLoadMethod]
        private static void ResumePlayPreview()
        {
            if (!SessionState.GetBool(PreviewSession, false)) return;
            previewFrames = 0;
            previewStart = EditorApplication.timeSinceStartup;
            EditorApplication.update += TickPreview;
        }

        private static void TickPreview()
        {
            if (EditorApplication.timeSinceStartup - previewStart > 30)
            {
                SessionState.SetBool(PreviewSession, false);
                EditorApplication.Exit(2);
                return;
            }
            if (!EditorApplication.isPlaying) return;
            previewFrames++;
            if (previewFrames == 10)
            {
                var receiver = UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                receiver.OnFlutterCommand(JsonUtility.ToJson(new PreviewEnvelope {
                    method = "loadAvatar", json = "{\"requestId\":\"offline-preview\",\"modelUrl\":\"unity://masso/avatar_agent\"}" }));
                receiver.OnFlutterCommand(JsonUtility.ToJson(new PreviewEnvelope {
                    method = "setFraming", json = "{\"mode\":\"hero_full_body\"}" }));
                receiver.OnFlutterCommand(JsonUtility.ToJson(new PreviewEnvelope {
                    method = "setLocalAvatarVisible", json = "{\"visible\":true}" }));
            }
            if (previewFrames < 90) return;
            EditorApplication.update -= TickPreview;
            SessionState.SetBool(PreviewSession, false);
            try { VerifyAndRender(); EditorApplication.Exit(0); }
            catch (Exception error) { Debug.LogException(error); EditorApplication.Exit(1); }
        }

        [Serializable] private sealed class PreviewEnvelope { public string method; public string json; }

        public static void VerifyAndRender()
        {
            if (!EditorApplication.isPlaying) MaasoDefaultAvatarSceneBuilder.ValidateScene();
            Vrm10Instance vrm = UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
            Animator animator = vrm.GetComponentInChildren<Animator>(true);
            AnimationClip clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(
                "Assets/MaasoAvatar/Animations/Humanoid/OfflineIdle.anim");
            if (clip == null || !clip.humanMotion)
                throw new InvalidOperationException("Offline idle must be a real Humanoid clip.");
            if (!EditorApplication.isPlaying)
            {
                animator.Rebind();
                animator.Update(0f);
                clip.SampleAnimation(animator.gameObject, 0f);
            }
            Renderer[] renderers = vrm.GetComponentsInChildren<Renderer>(true)
                .Where(r => r.enabled && r.gameObject.activeInHierarchy).ToArray();
            if (renderers.Length == 0 || renderers.Any(r => r.sharedMaterials.Any(m => m == null)))
                throw new InvalidOperationException("Bundled model has missing renderers or materials.");
            Bounds bounds = renderers[0].bounds;
            foreach (Renderer renderer in renderers.Skip(1)) bounds.Encapsulate(renderer.bounds);
            if (bounds.size.y < 0.5f || bounds.size.x < 0.1f)
                throw new InvalidOperationException("Bundled model bounds are not full-body sized.");
            var audit = AvatarRetiredAssetBuildGuard.CreateAudit(
                AssetDatabase.GetDependencies(MaasoDefaultAvatarSceneBuilder.ScenePath, true),
                "EditorScene", "offline-avatar-scene");
            AvatarRetiredAssetBuildGuard.RequireAllowed(audit);
            string output = Environment.GetEnvironmentVariable("OPEN_MAASO_AVATAR_PREVIEW");
            if (string.IsNullOrWhiteSpace(output))
                throw new InvalidOperationException("Set OPEN_MAASO_AVATAR_PREVIEW to a local PNG output path.");
            Camera camera = Camera.main;
            var previousTarget = camera.targetTexture;
            var previousPosition = camera.transform.position;
            var previousRotation = camera.transform.rotation;
            var previousAspect = camera.aspect;
            var previousActive = RenderTexture.active;
            RenderTexture target = null;
            Texture2D image = null;
            try
            {
                target = new RenderTexture(720, 1280, 24, RenderTextureFormat.ARGB32);
                target.Create();
                camera.targetTexture = target;
                camera.aspect = 720f / 1280f;
                float halfFov = camera.fieldOfView * Mathf.Deg2Rad * 0.5f;
                float distance = Mathf.Max(bounds.extents.y / Mathf.Tan(halfFov),
                    bounds.extents.x / (Mathf.Tan(halfFov) * camera.aspect)) * 1.15f;
                camera.transform.position = bounds.center + Vector3.forward * distance;
                camera.transform.LookAt(bounds.center);
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = Color.white;
                camera.Render();
                RenderTexture.active = target;
                image = new Texture2D(target.width, target.height, TextureFormat.RGB24, false);
                image.ReadPixels(new Rect(0, 0, target.width, target.height), 0, 0);
                image.Apply();
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output)));
                File.WriteAllBytes(output, image.EncodeToPNG());
                Debug.Log("[OpenMaasoAvatar] VERIFIED human=true idleHuman=true renderers=" +
                    renderers.Length + " height=" + bounds.size.y + " width=" + bounds.size.x +
                    " freeSource=" + audit.retainedOpenSourceAvatarFound);
            }
            finally
            {
                camera.targetTexture = previousTarget;
                camera.transform.SetPositionAndRotation(previousPosition, previousRotation);
                camera.aspect = previousAspect;
                RenderTexture.active = previousActive;
                if (image != null) UnityEngine.Object.DestroyImmediate(image);
                if (target != null) { target.Release(); UnityEngine.Object.DestroyImmediate(target); }
            }
        }
    }
}
#endif
