#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Maaso.Avatar;
using UniVRM10;
using UnityEditor;
using UnityEditor.Animations;
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
            "Assets/MaasoAvatar/Models/Default/OpenMaaso.vrm";
        public const string ControllerPath =
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        public const string DefaultAvatarName = "MaasoDefaultAvatar";
        private const string ReviewedVrmSha256 =
            "12c2b97e95e700783a6a550dc0eee2d7880aeedccef9ae67bc4c5a2f0f2631a2";

        [MenuItem("Maaso/Avatar/Rebuild Default VRM Scene", false, 5)]
        public static void RebuildScene()
        {
            if (!File.Exists(DefaultVrmPath))
            {
                throw new FileNotFoundException(
                    "Bundled default VRM is missing.",
                    DefaultVrmPath);
            }

            RequireReviewedModel();
            PlayerSettings.colorSpace = ColorSpace.Linear;
            EnsureAssetFolder("Assets/MaasoAvatar/Scenes");
            AssetDatabase.ImportAsset(
                DefaultVrmPath,
                ImportAssetOptions.ForceSynchronousImport |
                ImportAssetOptions.ForceUpdate);

            GameObject avatarAsset =
                AssetDatabase.LoadAssetAtPath<GameObject>(DefaultVrmPath);
            if (avatarAsset == null)
            {
                throw new InvalidOperationException(
                    "UniVRM did not import the bundled model as a GameObject.");
            }

            Scene scene = EditorSceneManager.NewScene(
                NewSceneSetup.EmptyScene,
                NewSceneMode.Single);
            ConfigureRenderSettings();
            CreateOfflineFloor();

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
            animator.runtimeAnimatorController = EnsureOfflineController(animator);
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
            var offlineReceiver = new SerializedObject(receiver);
            offlineReceiver.FindProperty("designedIdleStateName").stringValue = "Idle";
            offlineReceiver.ApplyModifiedPropertiesWithoutUndo();

            EditorSceneManager.SaveScene(scene, ScenePath);
            UpdateBuildSettings();
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            ValidateScene();
            Debug.Log("[MaasoAvatar] Rebuilt bundled VRM scene: " + ScenePath);
        }

        public static void RebuildAndExportIOS()
        {
            RebuildScene();
            MaasoUnityLibraryExporter.ExportIOS();
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

        // Original, self-contained idle. No commercial motion assets or room
        // content are required by the public offline scene.
        private static void RequireReviewedModel()
        {
            using (var hash = SHA256.Create())
            using (var stream = File.OpenRead(DefaultVrmPath))
            {
                var hex = new StringBuilder(64);
                foreach (byte value in hash.ComputeHash(stream)) hex.Append(value.ToString("x2"));
                if (!string.Equals(hex.ToString(), ReviewedVrmSha256, StringComparison.Ordinal))
                    throw new InvalidDataException("The default VRM differs from its reviewed redistribution source.");
            }
        }

        private static RuntimeAnimatorController EnsureOfflineController(Animator animator)
        {
            EnsureAssetFolder("Assets/MaasoAvatar/Animations/Humanoid");
            string clipPath = "Assets/MaasoAvatar/Animations/Humanoid/OfflineIdle.anim";
            AnimationClip clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(clipPath);
            bool newClip = clip == null;
            if (newClip) clip = new AnimationClip { name = "OfflineIdle", frameRate = 30f };
            {
                HumanPose pose = new HumanPose();
                using (var poseHandler = new HumanPoseHandler(animator.avatar, animator.transform))
                    poseHandler.GetHumanPose(ref pose);
                string[] axes = { "x", "y", "z" };
                for (int axis = 0; axis < 3; axis++)
                    AnimationUtility.SetEditorCurve(clip,
                        EditorCurveBinding.FloatCurve("", typeof(Animator), "RootT." + axes[axis]),
                        AnimationCurve.Constant(0f, 4f, pose.bodyPosition[axis]));
                string[] rotationAxes = { "x", "y", "z", "w" };
                for (int axis = 0; axis < 4; axis++)
                    AnimationUtility.SetEditorCurve(clip,
                        EditorCurveBinding.FloatCurve("", typeof(Animator), "RootQ." + rotationAxes[axis]),
                        AnimationCurve.Constant(0f, 4f, pose.bodyRotation[axis]));
                foreach (string muscle in new[] { "Left Arm Down-Up", "Right Arm Down-Up" })
                    AnimationUtility.SetEditorCurve(clip,
                        EditorCurveBinding.FloatCurve("", typeof(Animator), muscle),
                        AnimationCurve.Constant(0f, 4f, -0.75f));
                AnimationUtility.SetEditorCurve(clip,
                    EditorCurveBinding.FloatCurve("", typeof(Animator), "Chest Front-Back"),
                    new AnimationCurve(new Keyframe(0f, 0f), new Keyframe(2f, 0.025f), new Keyframe(4f, 0f)));
                var settings = AnimationUtility.GetAnimationClipSettings(clip);
                settings.loopTime = true;
                AnimationUtility.SetAnimationClipSettings(clip, settings);
                if (newClip) AssetDatabase.CreateAsset(clip, clipPath);
                else EditorUtility.SetDirty(clip);
            }
            AnimatorController controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            if (controller == null)
            {
                controller = AnimatorController.CreateAnimatorControllerAtPath(ControllerPath);
                AnimatorState idle = controller.layers[0].stateMachine.AddState("Idle");
                idle.motion = clip;
                controller.layers[0].stateMachine.defaultState = idle;
            }
            return controller;
        }

        private static void CreateOfflineFloor()
        {
            GameObject floor = GameObject.CreatePrimitive(PrimitiveType.Plane);
            floor.name = "OfflineWhiteFloor";
            floor.transform.position = new Vector3(0f, -0.015f, 0f);
            floor.transform.localScale = Vector3.one * 2f;
            EnsureAssetFolder("Assets/MaasoAvatar/Materials");
            const string materialPath = "Assets/MaasoAvatar/Materials/OfflineWhiteFloor.mat";
            Material material = AssetDatabase.LoadAssetAtPath<Material>(materialPath);
            if (material == null)
            {
                material = new Material(Shader.Find("Standard"));
                material.color = new Color(0.96f, 0.965f, 0.972f, 1f);
                material.SetFloat("_Glossiness", 0f);
                AssetDatabase.CreateAsset(material, materialPath);
            }
            floor.GetComponent<Renderer>().sharedMaterial = material;
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
            camera.backgroundColor = Color.white;
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
            light.color = Color.white;
            light.intensity = 0.65f;
            light.shadows = LightShadows.Soft;
            RenderSettings.sun = light;
            return light;
        }

        private static void ConfigureRenderSettings()
        {
            RenderSettings.fog = false;
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.20f, 0.20f, 0.20f);
            RenderSettings.ambientEquatorColor = new Color(0.18f, 0.18f, 0.18f);
            RenderSettings.ambientGroundColor = new Color(0.15f, 0.15f, 0.15f);
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
            EditorBuildSettings.scenes = new[]
            {
                new EditorBuildSettingsScene(ScenePath, true),
            };
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
