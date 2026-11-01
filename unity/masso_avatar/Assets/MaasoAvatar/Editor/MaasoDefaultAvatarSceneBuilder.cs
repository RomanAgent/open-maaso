#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using Maaso.Avatar;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Rebuilds the shipped Avatar scene from the reviewed VRM source asset.
    /// The Player contains the imported scene instance, so boot never depends
    /// on a runtime file import, download, or machine-local model path.
    /// </summary>
    public static class MaasoDefaultAvatarSceneBuilder
    {
        public const string ScenePath =
            "Assets/MaasoAvatar/Scenes/Companion.unity";
        public const string DefaultVrmPath =
            "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        public const string ControllerPath =
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        public const string DefaultAvatarName = "MaasoDefaultAvatar";

        [MenuItem("Maaso/Avatar/Rebuild Default VRM Scene", false, 5)]
        public static void RebuildScene()
        {
            if (!File.Exists(DefaultVrmPath))
            {
                throw new FileNotFoundException(
                    "Bundled default VRM is missing.",
                    DefaultVrmPath);
            }

            EnsureAssetFolder("Assets/MaasoAvatar/Scenes");
            AssetDatabase.ImportAsset(
                DefaultVrmPath,
                ImportAssetOptions.ForceSynchronousImport |
                ImportAssetOptions.ForceUpdate);

            GameObject avatarAsset =
                AssetDatabase.LoadAssetAtPath<GameObject>(DefaultVrmPath);
            RuntimeAnimatorController controller =
                AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(
                    ControllerPath);
            if (avatarAsset == null)
            {
                throw new InvalidOperationException(
                    "UniVRM did not import the bundled model as a GameObject.");
            }
            if (controller == null)
            {
                throw new InvalidOperationException(
                    "Maaso Humanoid controller is missing: " + ControllerPath);
            }

            Scene scene = EditorSceneManager.NewScene(
                NewSceneSetup.EmptyScene,
                NewSceneMode.Single);
            ConfigureRenderSettings();

            GameObject avatar = PrefabUtility.InstantiatePrefab(avatarAsset) as GameObject;
            if (avatar == null)
            {
                avatar = UnityEngine.Object.Instantiate(avatarAsset);
            }
            avatar.name = DefaultAvatarName;
            avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            avatar.transform.localScale = Vector3.one;

            Vrm10Instance vrm = avatar.GetComponentInChildren<Vrm10Instance>(true);
            Animator animator = avatar.GetComponentInChildren<Animator>(true);
            if (vrm == null || animator == null || animator.avatar == null ||
                !animator.avatar.isHuman || !animator.avatar.isValid)
            {
                throw new InvalidOperationException(
                    "Bundled default VRM must expose a valid Humanoid instance.");
            }
            animator.runtimeAnimatorController = controller;
            animator.applyRootMotion = false;
            vrm.LookAtTarget = null;
            vrm.LookAtTargetType =
                VRM10ObjectLookAt.LookAtTargetTypes.YawPitchValue;

            Light directionalLight = CreateDirectionalLight();
            Camera camera = CreateMainCamera();
            FrontFullBodyCamera framing =
                camera.gameObject.AddComponent<FrontFullBodyCamera>();
            framing.TargetRoot = avatar.transform;

            UnityWorldLightingController lighting =
                camera.gameObject.AddComponent<UnityWorldLightingController>();
            SetObjectReference(lighting, "backgroundCamera", camera);
            SetObjectReference(lighting, "directionalLight", directionalLight);

            UnityAvatarCommandReceiver receiver =
                camera.gameObject.AddComponent<UnityAvatarCommandReceiver>();
            SetObjectReference(receiver, "avatarRoot", avatar.transform);
            SetObjectReference(receiver, "bundledVrmInstance", vrm);
            SetObjectReference(receiver, "worldLighting", lighting);

            EditorSceneManager.SaveScene(scene, ScenePath);
            UpdateBuildSettings();
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            ValidateScene();
            Debug.Log("[MaasoAvatar] Rebuilt bundled VRM scene: " + ScenePath);
        }

        public static void RebuildSceneFromCommandLine()
        {
            RebuildScene();
        }

        public static void ValidateScene()
        {
            Scene scene = SceneManager.GetActiveScene();
            if (scene.path != ScenePath)
            {
                scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
            }

            UnityAvatarCommandReceiver receiver =
                UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
            Vrm10Instance vrm =
                UnityEngine.Object.FindAnyObjectByType<Vrm10Instance>();
            Camera camera = Camera.main;
            Animator animator = vrm == null
                ? null
                : vrm.GetComponentInChildren<Animator>(true);
            if (receiver == null || vrm == null || camera == null ||
                animator == null || animator.avatar == null ||
                !animator.avatar.isHuman || !animator.avatar.isValid)
            {
                throw new InvalidOperationException(
                    "Bundled VRM scene is incomplete or invalid: " + ScenePath);
            }
            if (animator.runtimeAnimatorController == null ||
                AssetDatabase.GetAssetPath(animator.runtimeAnimatorController) !=
                    ControllerPath)
            {
                throw new InvalidOperationException(
                    "Bundled VRM scene is not bound to the Maaso action controller.");
            }
            if (camera.GetComponent<FrontFullBodyCamera>() == null ||
                camera.GetComponent<UnityWorldLightingController>() == null)
            {
                throw new InvalidOperationException(
                    "Bundled VRM scene is missing camera or lighting behavior.");
            }

            var serializedReceiver = new SerializedObject(receiver);
            if (serializedReceiver.FindProperty("avatarRoot")?.objectReferenceValue !=
                    vrm.transform ||
                serializedReceiver.FindProperty("bundledVrmInstance")
                    ?.objectReferenceValue != vrm)
            {
                throw new InvalidOperationException(
                    "Bundled VRM is not explicitly bound to the command receiver.");
            }
        }

        private static Camera CreateMainCamera()
        {
            var cameraObject = new GameObject("Main Camera");
            cameraObject.tag = "MainCamera";
            cameraObject.transform.SetPositionAndRotation(
                new Vector3(0f, 0.69f, 3.64f),
                Quaternion.Euler(0f, 180f, 0f));
            cameraObject.AddComponent<AudioListener>();
            Camera camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(1f, 0.9843137f, 0.9490196f, 1f);
            camera.fieldOfView = 37.5f;
            camera.nearClipPlane = 0.3f;
            camera.farClipPlane = 1000f;
            camera.depth = -1f;
            camera.allowHDR = true;
            camera.allowMSAA = true;
            return camera;
        }

        private static Light CreateDirectionalLight()
        {
            var lightObject = new GameObject("Directional Light");
            lightObject.transform.SetPositionAndRotation(
                new Vector3(0f, 3f, 0f),
                Quaternion.Euler(50f, -30f, 0f));
            Light light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.color = new Color(1f, 0.95686275f, 0.8392157f, 1f);
            light.intensity = 1f;
            light.shadows = LightShadows.Soft;
            RenderSettings.sun = light;
            return light;
        }

        private static void ConfigureRenderSettings()
        {
            RenderSettings.fog = false;
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.212f, 0.227f, 0.259f);
            RenderSettings.ambientEquatorColor = new Color(0.114f, 0.125f, 0.133f);
            RenderSettings.ambientGroundColor = new Color(0.047f, 0.043f, 0.035f);
            RenderSettings.ambientIntensity = 1f;
        }

        private static void SetObjectReference(
            UnityEngine.Object target,
            string propertyName,
            UnityEngine.Object value)
        {
            var serialized = new SerializedObject(target);
            SerializedProperty property = serialized.FindProperty(propertyName);
            if (property == null)
            {
                throw new MissingFieldException(target.GetType().Name, propertyName);
            }
            property.objectReferenceValue = value;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            EditorUtility.SetDirty(target);
        }

        private static void UpdateBuildSettings()
        {
            EditorBuildSettingsScene[] existing = EditorBuildSettings.scenes;
            EditorBuildSettingsScene[] retained = existing
                .Where(entry => entry.path != ScenePath)
                .ToArray();
            EditorBuildSettings.scenes = new[]
                {
                    new EditorBuildSettingsScene(ScenePath, true),
                }
                .Concat(retained)
                .ToArray();
        }

        private static void EnsureAssetFolder(string path)
        {
            string[] segments = path.Split('/');
            string current = segments[0];
            for (int index = 1; index < segments.Length; index++)
            {
                string next = current + "/" + segments[index];
                if (!AssetDatabase.IsValidFolder(next))
                {
                    AssetDatabase.CreateFolder(current, segments[index]);
                }
                current = next;
            }
        }
    }
}
#endif
