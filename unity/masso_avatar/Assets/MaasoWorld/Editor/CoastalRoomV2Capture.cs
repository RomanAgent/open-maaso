using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using Maaso.Avatar;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.World.Editor
{
    /// <summary>Fixed-camera comparisons; this class runs only when explicitly invoked in Unity.</summary>
    public static class CoastalRoomV2Capture
    {
        public static readonly string[] StandardViews =
            { "sea", "interior", "west", "east", "linen_detail", "floor_detail" };
        public static string OutputDirectory => Path.GetFullPath(Path.Combine(
            Application.dataPath, "../../../docs/avatar/coastal_room_v2/unity"));

        [Serializable]
        private sealed class ViewReceipt
        {
            public string name;
            public string path;
            public int width;
            public int height;
            public Vector3 position;
            public Vector3 forward;
            public float verticalFieldOfView;
            public bool orthographic;
        }

        [Serializable]
        private sealed class CaptureReceipt
        {
            public string createdUtc;
            public string sourceSha256;
            public string colorTransform;
            public string renderPipeline;
            public string colorSpace;
            public string limitation;
            public ViewReceipt[] views;
        }

        [MenuItem("Maaso/World/Coastal V2/Build And Capture All")]
        public static void BuildAndCapture()
        {
            // Reuses the existing resource installation and real Home/avatar initialization.
            PersonalSpaceSceneBuilder.BuildCozyRoom();
            CaptureStandardViews();
            CapturePersonalSpace();
        }

        [MenuItem("Maaso/World/Coastal V2/Capture All Existing Assets")]
        public static void CaptureAll()
        {
            CaptureStandardViews();
            PersonalSpaceSceneBuilder.CapturePortraitPreview();
            CapturePersonalSpace();
        }

        [MenuItem("Maaso/World/Coastal V2/Capture Fixed Comparison Views")]
        public static void CaptureStandardViews()
        {
            RequireRenderingContract();
            CoastalRoomV2Importer.Manifest manifest = CoastalRoomV2Importer.ReadManifest();
            GameObject asset = AssetDatabase.LoadAssetAtPath<GameObject>(PersonalSpaceSceneBuilder.RuntimeModelPath);
            if (asset == null) throw new InvalidOperationException("Build the Coastal V2 runtime prefab before capturing it.");
            Scene scene = EditorSceneManager.NewPreviewScene();
            try
            {
                GameObject model = PrefabUtility.InstantiatePrefab(asset, scene) as GameObject;
                if (model == null) throw new InvalidOperationException("Could not instantiate the baked room.");
                CoastalRoomV2Importer.ValidateGeometry(model);
                if (model.GetComponentsInChildren<Light>(true).Length != 0)
                    throw new InvalidOperationException("Comparison views must not add real-time light to baked radiance.");
                var receipts = new List<ViewReceipt>();
                foreach (string name in StandardViews.Concat(new[] { "plan" }))
                {
                    CoastalRoomV2Importer.CameraEntry entry = manifest.cameras.SingleOrDefault(item => item.name == name);
                    if (entry == null) throw new InvalidOperationException("Missing authored comparison camera: " + name);
                    int width = name == "plan" ? 1024 : 1600;
                    int height = name == "plan" ? 1024 : 900;
                    receipts.Add(CaptureView(scene, model, entry,
                        Path.Combine(OutputDirectory, name + ".png"), width, height));
                }
                var receipt = new CaptureReceipt
                {
                    createdUtc = DateTime.UtcNow.ToString("O"),
                    sourceSha256 = manifest.sourceSha256,
                    colorTransform = manifest.colorTransform,
                    renderPipeline = "Built-in",
                    colorSpace = QualitySettings.activeColorSpace.ToString(),
                    limitation = "Real 3D meshes with display-referred Cycles atlases. Static reflections and translucent curtains are approximations; pixel identity is not asserted.",
                    views = receipts.ToArray(),
                };
                File.WriteAllText(Path.Combine(OutputDirectory, "capture-report.json"), JsonUtility.ToJson(receipt, true));
                Debug.Log("[CoastalV2][Capture] " + OutputDirectory);
            }
            finally
            {
                EditorSceneManager.ClosePreviewScene(scene);
            }
        }

        public static void CapturePreview(Scene scene, GameObject model)
        {
            RequireRenderingContract();
            CoastalRoomV2Importer.CameraEntry sea = CoastalRoomV2Importer.ReadManifest().cameras.Single(item => item.name == "sea");
            string path = CoastalRoomV2Importer.ProjectFile(PersonalSpaceSceneBuilder.PreviewPath);
            CaptureView(scene, model, sea, path, 1600, 900);
            AssetDatabase.ImportAsset(PersonalSpaceSceneBuilder.PreviewPath, ImportAssetOptions.ForceSynchronousImport);
        }

        [MenuItem("Maaso/World/Coastal V2/Capture Runtime Personal Space")]
        public static void CapturePersonalSpace()
        {
            RequireRenderingContract();
            const string companionScene = "Assets/MaasoAvatar/Scenes/Companion.unity";
            Scene scene = EditorSceneManager.OpenScene(companionScene, OpenSceneMode.Single);
            RenderTexture target = null;
            Texture2D image = null;
            RenderTexture previousTarget = RenderTexture.active;
            try
            {
                Camera camera = scene.GetRootGameObjects()
                    .SelectMany(root => root.GetComponentsInChildren<Camera>(true))
                    .Single(value => value.CompareTag("MainCamera"));
                camera.scene = scene;
                FrontFullBodyCamera framing = camera.GetComponent<FrontFullBodyCamera>();
                GameObject mapAsset = Resources.Load<GameObject>(PersistentWorldMapController.ResourceName);
                if (framing == null || mapAsset == null)
                    throw new InvalidOperationException("Build the room and avatar camera before capturing personal space.");
                GameObject mapObject = PrefabUtility.InstantiatePrefab(mapAsset, scene) as GameObject;
                PersistentWorldMapController map = mapObject != null
                    ? mapObject.GetComponent<PersistentWorldMapController>() : null;
                if (map == null) throw new InvalidOperationException("The runtime map controller is missing.");
                PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera, map);
                Transform avatar = framing.TargetRoot;
                if (avatar == null || !avatar.GetComponentsInChildren<SkinnedMeshRenderer>(false)
                    .Any(renderer => renderer.enabled && !renderer.forceRenderingOff &&
                        (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0))
                    throw new InvalidOperationException("Personal-space capture requires the visible runtime avatar.");
                camera.aspect = 9f / 16f;
                framing.FrameNow();
                map.SetWorldActive(true);
                if (map.WorldPlayCenter == null)
                    throw new InvalidOperationException("The runtime room has no world play center.");
                Vector3 spawn = map.WorldPlayCenter.position;
                // Home initialization has already placed the avatar's feet on the floor.
                avatar.position = new Vector3(spawn.x, avatar.position.y, spawn.z);
                avatar.rotation = WorldCameraDirector.CalculateOwnerEntryRotation(
                    avatar.position, camera.aspect, avatar.rotation);
                PortraitDepthOfField portrait = camera.GetComponent<PortraitDepthOfField>();
                if (portrait != null) portrait.enabled = false;
                WorldCameraDirector director = camera.GetComponent<WorldCameraDirector>();
                if (director == null) director = camera.gameObject.AddComponent<WorldCameraDirector>();
                if (!director.EnterWorld(camera, framing, avatar, null))
                    throw new InvalidOperationException("The runtime camera refused to enter personal space.");
                // EditMode does not advance the normal update loop. Run its existing
                // transition and occlusion code, as the runtime boundary tests do.
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                MethodInfo advance = typeof(WorldCameraDirector).GetMethod("UpdateTransition", flags);
                if (advance == null) throw new MissingMethodException("WorldCameraDirector.UpdateTransition");
                advance.Invoke(director, new object[] { Time.realtimeSinceStartup + WorldCameraDirector.EnterDurationSeconds + .1f });
                if (director.Phase != WorldCameraPhase.Active)
                    throw new InvalidOperationException("The camera did not reach the built-in personal-space view.");
                WorldCameraOcclusion occlusion = camera.GetComponent<WorldCameraOcclusion>();
                MethodInfo prepare = typeof(WorldCameraOcclusion).GetMethod("PrepareFrame", flags);
                if (occlusion == null || prepare == null)
                    throw new InvalidOperationException("The runtime cutaway component is missing.");
                prepare.Invoke(occlusion, new object[] { Time.realtimeSinceStartup, 1f });
                Renderer roof = mapObject.GetComponentsInChildren<Renderer>(true)
                    .SingleOrDefault(renderer => renderer.name == "V2_Ceiling");
                Vector3 roomCamera = map.transform.InverseTransformPoint(camera.transform.position);
                if (roof == null || Mathf.Abs(roomCamera.x) > WorldCameraDirector.PersonalSpaceCameraLimit + .001f ||
                    Mathf.Abs(roomCamera.z) > WorldCameraDirector.PersonalSpaceCameraLimit + .001f ||
                    Mathf.Abs(roomCamera.y - WorldCameraDirector.PersonalSpaceEyeHeight) > .001f ||
                    camera.transform.position.y >= roof.bounds.min.y)
                    throw new InvalidOperationException("The personal-space camera must remain at eye level inside the room.");
                target = new RenderTexture(900, 1600, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB)
                { name = "CoastalV2RuntimePersonalSpace", antiAliasing = 4 };
                target.Create();
                camera.targetTexture = target;
                camera.Render();
                RenderTexture.active = target;
                image = new Texture2D(900, 1600, TextureFormat.RGB24, false, false);
                image.ReadPixels(new Rect(0, 0, 900, 1600), 0, 0);
                image.Apply();
                Directory.CreateDirectory(OutputDirectory);
                string path = Path.Combine(OutputDirectory, "personal-space.png");
                File.WriteAllBytes(path, image.EncodeToPNG());
                var receipt = new ViewReceipt
                {
                    name = "personal-space", path = path, width = 900, height = 1600,
                    position = camera.transform.position, forward = camera.transform.forward,
                    verticalFieldOfView = camera.fieldOfView, orthographic = camera.orthographic,
                };
                File.WriteAllText(Path.Combine(OutputDirectory, "personal-space-camera.json"), JsonUtility.ToJson(receipt, true));
                Debug.Log("[CoastalV2][Capture] Runtime avatar and indoor eye-level view: " + path);
            }
            finally
            {
                RenderTexture.active = previousTarget;
                if (target != null) { target.Release(); Object.DestroyImmediate(target); }
                if (image != null) Object.DestroyImmediate(image);
                // No avatar, camera, material override or preview state is saved.
                EditorSceneManager.OpenScene(companionScene, OpenSceneMode.Single);
            }
        }

        public static float VerticalFieldOfView(float lens, float aspect)
        {
            if (float.IsNaN(lens) || float.IsInfinity(lens) || lens <= 0f ||
                float.IsNaN(aspect) || float.IsInfinity(aspect) || aspect <= 0f)
                throw new ArgumentException("A physical camera needs positive finite lens and aspect values.");
            // Blender authored all perspective cameras with 36 mm horizontal sensor fit.
            return 2f * Mathf.Atan(18f / (lens * aspect)) * Mathf.Rad2Deg;
        }

        private static ViewReceipt CaptureView(Scene scene, GameObject model,
            CoastalRoomV2Importer.CameraEntry entry, string path, int width, int height)
        {
            GameObject cameraObject = new GameObject("CoastalV2ComparisonCamera");
            SceneManager.MoveGameObjectToScene(cameraObject, scene);
            RenderTexture target = null;
            Texture2D image = null;
            RenderTexture previousTarget = RenderTexture.active;
            Renderer ceiling = model.GetComponentsInChildren<Renderer>(true).SingleOrDefault(item => item.name == "V2_Ceiling");
            bool oldCeiling = ceiling != null && ceiling.enabled;
            try
            {
                Camera camera = cameraObject.AddComponent<Camera>();
                // Layer masks span all loaded scenes; constrain this comparison
                // to its isolated room even when another map remains loaded.
                camera.scene = scene;
                camera.enabled = false;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = Color.black;
                camera.allowHDR = false;
                camera.allowMSAA = true;
                camera.nearClipPlane = .035f;
                camera.farClipPlane = 200f;
                camera.cullingMask = 1 << LayerMask.NameToLayer("PersonalSpaceEnvironment");
                camera.aspect = (float)width / height;
                camera.fieldOfView = VerticalFieldOfView(entry.lens, camera.aspect);
                camera.orthographic = entry.type == "ORTHO";
                if (camera.orthographic) camera.orthographicSize = entry.ortho / (2f * camera.aspect);
                Vector3 position = CoastalRoomV2Importer.BlenderToUnity(entry.position);
                Vector3 direction = (CoastalRoomV2Importer.BlenderToUnity(entry.target) - position).normalized;
                Vector3 up = Mathf.Abs(Vector3.Dot(direction, Vector3.up)) > .999f ? Vector3.back : Vector3.up;
                camera.transform.SetPositionAndRotation(position, Quaternion.LookRotation(direction, up));
                if (entry.name == "plan" && ceiling != null) ceiling.enabled = false;
                target = new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB)
                {
                    name = "CoastalV2_" + entry.name,
                    antiAliasing = 4,
                };
                target.Create();
                camera.targetTexture = target;
                camera.Render();
                RenderTexture.active = target;
                image = new Texture2D(width, height, TextureFormat.RGB24, false, false);
                image.ReadPixels(new Rect(0, 0, width, height), 0, 0);
                image.Apply();
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllBytes(path, image.EncodeToPNG());
                return new ViewReceipt
                {
                    name = entry.name, path = path, width = width, height = height,
                    position = camera.transform.position, forward = camera.transform.forward,
                    verticalFieldOfView = camera.fieldOfView, orthographic = camera.orthographic,
                };
            }
            finally
            {
                if (ceiling != null) ceiling.enabled = oldCeiling;
                RenderTexture.active = previousTarget;
                if (target != null) { target.Release(); Object.DestroyImmediate(target); }
                if (image != null) Object.DestroyImmediate(image);
                Object.DestroyImmediate(cameraObject);
            }
        }

        private static void RequireRenderingContract()
        {
            if (GraphicsSettings.currentRenderPipeline != null || QualitySettings.activeColorSpace != ColorSpace.Linear)
                throw new InvalidOperationException("The baked room comparison requires Built-in rendering and Linear color space.");
        }
    }
}
