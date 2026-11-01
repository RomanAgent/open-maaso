using System;
using System.IO;
using System.Linq;
using System.Reflection;
using Maaso.Avatar;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.World.Editor
{
    public static class WorldCameraOcclusionPreview
    {
        private const string CompanionScene = "Assets/MaasoAvatar/Scenes/Companion.unity";
        private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;

        [MenuItem("Maaso/World/Capture Room Occlusion Preview")]
        public static void Capture() => CaptureAtOffset(Vector3.zero, "world_occlusion");

        [MenuItem("Maaso/World/Capture Window Occlusion Preview")]
        public static void CaptureWindow() =>
            CaptureAtOffset(new Vector3(0f, 0f, -4f), "world_window_occlusion");

        [MenuItem("Maaso/World/Capture Window Left Occlusion Preview")]
        public static void CaptureWindowLeft() =>
            CaptureAtOffset(new Vector3(-2.2f, 0f, -4f), "world_window_left_occlusion");

        [MenuItem("Maaso/World/Capture Window Right Occlusion Preview")]
        public static void CaptureWindowRight() =>
            CaptureAtOffset(new Vector3(2.2f, 0f, -4f), "world_window_right_occlusion");

        public static void CaptureWindowViews()
        {
            CaptureWindow();
            CaptureWindowLeft();
            CaptureWindowRight();
        }

        private static void CaptureAtOffset(Vector3 offset, string filenamePrefix)
        {
            for (int index = 0; index < SceneManager.sceneCount; index++)
                if (SceneManager.GetSceneAt(index).isDirty)
                    throw new InvalidOperationException("Save scene changes before capturing a room preview.");

            SceneSetup[] previousScenes = EditorSceneManager.GetSceneManagerSetup();
            RenderTexture previousActive = RenderTexture.active;
            RenderTexture previousCameraTarget = null;
            RenderTexture target = null;
            Texture2D image = null;
            Camera camera = null;
            WorldCameraOcclusion effect = null;
            GameObject room = null;
            try
            {
                Scene scene = EditorSceneManager.OpenScene(CompanionScene, OpenSceneMode.Single);
                camera = scene.GetRootGameObjects()
                    .SelectMany(root => root.GetComponentsInChildren<Camera>(true))
                    .Single(value => value.CompareTag("MainCamera"));
                previousCameraTarget = camera.targetTexture;
                GameObject prefab = Resources.Load<GameObject>(PersistentWorldMapController.ResourceName);
                if (prefab == null) throw new InvalidOperationException("The personal room prefab is missing.");
                room = PrefabUtility.InstantiatePrefab(prefab, scene) as GameObject;
                if (room == null) throw new InvalidOperationException("Unable to instantiate the personal room.");
                PersistentWorldMapController map = room.GetComponent<PersistentWorldMapController>();
                typeof(PersonalSpaceSceneBuilder).GetMethod("PrepareRuntimePortrait",
                    BindingFlags.Static | BindingFlags.NonPublic)?.Invoke(null, new object[] { camera, map });
                FrontFullBodyCamera framing = camera.GetComponent<FrontFullBodyCamera>();
                Transform owner = framing != null ? framing.TargetRoot : null;
                if (owner == null) throw new InvalidOperationException("The shipped avatar could not be prepared.");
                map.SetWorldActive(true);
                owner.position += offset;
                camera.aspect = 9f / 16f;
                camera.allowMSAA = false;
                owner.rotation = WorldCameraDirector.CalculateOwnerEntryRotation(
                    owner.position, camera.aspect, owner.rotation);
                WorldCameraDirector director = camera.GetComponent<WorldCameraDirector>();
                if (director == null) director = camera.gameObject.AddComponent<WorldCameraDirector>();
                if (!director.EnterWorld(camera, framing, owner, null))
                    throw new InvalidOperationException("Unable to enter the world camera preview.");
                float now = Time.realtimeSinceStartup;
                InvokePrivate(director, "UpdateTransition", now + 2f);
                // Capture synchronously: keep the director active for its target
                // contract without allowing an editor update to advance the pose.
                var pose = WorldCameraDirector.CalculateOwnerBirdseyePose(
                    owner.position, WorldCameraDirector.WorldFieldOfView, camera.aspect);
                camera.transform.SetPositionAndRotation(pose.Position, pose.Rotation);
                camera.fieldOfView = WorldCameraDirector.WorldFieldOfView;
                effect = camera.GetComponent<WorldCameraOcclusion>();
                target = new RenderTexture(900, 1600, 24, RenderTextureFormat.ARGB32)
                {
                    name = "RoomOcclusionPreview",
                    antiAliasing = 1,
                };
                target.Create();
                camera.targetTexture = target;
                image = new Texture2D(900, 1600, TextureFormat.RGB24, false);
                string directory = Path.GetFullPath(Path.Combine(
                    Application.dataPath, "../../../docs/avatar/cozy_room"));
                Directory.CreateDirectory(directory);
                foreach (bool reveal in new[] { false, true })
                {
                    effect.enabled = reveal;
                    if (reveal)
                    {
                        InvokePrivate(effect, "PrepareFrame", Time.realtimeSinceStartup, 0.3f);
                        InvokePrivate(effect, "RestoreRenderers");
                    }
                    camera.Render();
                    RenderTexture.active = target;
                    image.ReadPixels(new Rect(0, 0, 900, 1600), 0, 0);
                    image.Apply();
                    File.WriteAllBytes(Path.Combine(directory,
                        filenamePrefix + (reveal ? "_after.png" : "_before.png")), image.EncodeToPNG());
                }
                Debug.Log($"[WorldOcclusion][Preview] {filenamePrefix} owner={owner.position:F3} " +
                    $"camera={camera.transform.position:F3} output={directory}");
            }
            finally
            {
                if (effect != null) effect.enabled = false;
                if (camera != null) camera.targetTexture = previousCameraTarget;
                RenderTexture.active = previousActive;
                if (target != null)
                {
                    target.Release();
                    Object.DestroyImmediate(target);
                }
                if (image != null) Object.DestroyImmediate(image);
                if (room != null) Object.DestroyImmediate(room);
                // Reload from disk; never serialize preview poses or materials.
                if (previousScenes.Length > 0 && previousScenes.All(value => !string.IsNullOrEmpty(value.path)))
                    EditorSceneManager.RestoreSceneManagerSetup(previousScenes);
                else
                    EditorSceneManager.OpenScene(CompanionScene, OpenSceneMode.Single);
            }
        }

        private static void InvokePrivate(object target, string method, params object[] arguments)
        {
            MethodInfo info = target.GetType().GetMethod(method, PrivateInstance);
            if (info == null) throw new MissingMethodException(target.GetType().Name, method);
            info.Invoke(target, arguments);
        }
    }
}
