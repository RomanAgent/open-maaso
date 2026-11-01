using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Maaso.Avatar;
using Maaso.World;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.World.Editor
{
    public static class PersonalSpaceSceneBuilder
    {
        public const string ModelPath =
            "Assets/MaasoWorld/PersonalSpace/Models/PersonalSpace.fbx";
        public const string ScenePath =
            "Assets/MaasoWorld/Scenes/PersonalSpace.unity";
        public const string MaterialPath =
            "Assets/MaasoWorld/PersonalSpace/WhiteModel.mat";
        public const string RuntimeMaterialPath =
            "Assets/MaasoWorld/Resources/PersonalSpaceWhiteModel.mat";
        public const string RuntimeModelPath =
            "Assets/MaasoWorld/Resources/PersonalSpaceModel.prefab";
        public const string PreviewPath =
            "Assets/MaasoWorld/PersonalSpace/PersonalSpaceUnityPreview.png";
        private const float RoomSize = 8f;
        private const int PreviewSize = 1024;
        private const string SceneRootName = "PersonalSpaceSceneRoot";
        private const string EnvironmentName = "PersonalSpaceEnvironment";

        [MenuItem("Maaso/World/Build Cozy Room And Install Portrait Camera")]
        public static void BuildCozyRoom()
        {
            Build();
            PersistentWorldMapBuilder.CreatePersonalSpaceMap();
            InstallPortraitCamera();
            CapturePortraitPreview();
        }

        private static void InstallPortraitCamera()
        {
            const string companionScene = "Assets/MaasoAvatar/Scenes/Companion.unity";
            Scene scene = EditorSceneManager.OpenScene(companionScene, OpenSceneMode.Single);
            Camera camera = scene.GetRootGameObjects()
                .SelectMany(root => root.GetComponentsInChildren<Camera>(true))
                .Single(value => value.CompareTag("MainCamera"));
            camera.scene = scene;
            if (camera.GetComponent<PortraitDepthOfField>() == null)
            {
                camera.gameObject.AddComponent<PortraitDepthOfField>();
            }
            camera.depthTextureMode |= DepthTextureMode.Depth;
            if (!EditorSceneManager.SaveScene(scene, companionScene))
            {
                throw new InvalidOperationException("Unable to install the portrait camera.");
            }
            AssetDatabase.SaveAssets();
        }

        [MenuItem("Maaso/World/Capture Cozy Room Portrait Preview")]
        public static void CapturePortraitPreview()
        {
            const string companionScene = "Assets/MaasoAvatar/Scenes/Companion.unity";
            Scene scene = EditorSceneManager.OpenScene(companionScene, OpenSceneMode.Single);
            Camera camera = scene.GetRootGameObjects()
                .SelectMany(root => root.GetComponentsInChildren<Camera>(true))
                .Single(value => value.CompareTag("MainCamera"));
            FrontFullBodyCamera framing = camera.GetComponent<FrontFullBodyCamera>();
            PortraitDepthOfField portrait = camera.GetComponent<PortraitDepthOfField>();
            GameObject mapAsset = Resources.Load<GameObject>(PersistentWorldMapController.ResourceName);
            if (framing == null || portrait == null || mapAsset == null)
            {
                throw new InvalidOperationException("Build the cozy room before capturing its portrait.");
            }
            GameObject map = PrefabUtility.InstantiatePrefab(mapAsset, scene) as GameObject;
            if (map == null)
            {
                throw new InvalidOperationException("Unable to instantiate the room for portrait verification.");
            }

            RenderTexture target = null;
            Texture2D image = null;
            RenderTexture previousTarget = RenderTexture.active;
            RenderTexture previousCameraTarget = camera.targetTexture;
            string outputDirectory = Path.GetFullPath(Path.Combine(
                Application.dataPath, "../../../docs/avatar/coastal_room_v2/unity"));
            Directory.CreateDirectory(outputDirectory);
            try
            {
                // Reuse the shipped avatar, framing, and authoritative daylight.
                // This preview exercises the actual Unity image effect and mask.
                PrepareRuntimePortrait(camera, map.GetComponent<PersistentWorldMapController>());
                camera.aspect = 9f / 16f;
                framing.FrameNow();
                portrait.enabled = true;
                Transform avatar = framing.TargetRoot;
                bool visibleAvatar = avatar != null && avatar
                    .GetComponentsInChildren<SkinnedMeshRenderer>(false)
                    .Any(renderer => renderer.enabled && !renderer.forceRenderingOff &&
                        (camera.cullingMask & (1 << renderer.gameObject.layer)) != 0);
                if (!visibleAvatar || !portrait.UpdateFocus() || !portrait.CanRender)
                {
                    throw new InvalidOperationException(
                        "The Home preview requires a visible avatar and an active portrait focus.");
                }
                LogRoomGeometry(map, camera);
                target = new RenderTexture(900, 1600, 24, RenderTextureFormat.ARGB32)
                {
                    name = "CozyRoomPortraitPreview",
                    antiAliasing = 4,
                };
                target.Create();
                camera.targetTexture = target;
                image = new Texture2D(900, 1600, TextureFormat.RGB24, false);
                foreach (bool enabled in new[] { false, true })
                {
                    portrait.enabled = enabled;
                    camera.Render();
                    if (enabled && (!portrait.UpdateFocus() || !portrait.CanRender))
                    {
                        throw new InvalidOperationException(
                            "The Home preview lost its avatar focus while rendering.");
                    }
                    RenderTexture.active = target;
                    image.ReadPixels(new Rect(0, 0, 900, 1600), 0, 0);
                    image.Apply();
                    string fileName = enabled
                        ? "home.png"
                        : "home-sharp.png";
                    File.WriteAllBytes(Path.Combine(outputDirectory, fileName), image.EncodeToPNG());
                }
                Debug.Log($"[PersonalSpace][Portrait] focus={portrait.FocusDistance:F2} " +
                    $"backgroundStart={portrait.BackgroundStartDistance:F2} " +
                    $"canRender={portrait.CanRender} output={outputDirectory}");
            }
            finally
            {
                camera.targetTexture = previousCameraTarget;
                RenderTexture.active = previousTarget;
                if (target != null)
                {
                    target.Release();
                    Object.DestroyImmediate(target);
                }
                if (image != null) Object.DestroyImmediate(image);
                Object.DestroyImmediate(map);
                // Preview-only objects and settings never enter Companion.unity.
                EditorSceneManager.OpenScene(companionScene, OpenSceneMode.Single);
            }
        }

        public static void InspectCozyRoom()
        {
            GameObject asset = AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath);
            GameObject instance = Object.Instantiate(asset);
            try
            {
                LogRoomGeometry(instance, Camera.main);
            }
            finally
            {
                Object.DestroyImmediate(instance);
            }
        }

        private static void LogRoomGeometry(GameObject room, Camera camera)
        {
            foreach (Renderer renderer in room.GetComponentsInChildren<Renderer>(true))
            {
                if (renderer.name == "PS_Window_Frame" || renderer.name == "PS_Exterior_Sky" ||
                    renderer.name == "PS_FloorLamp_Shade" || renderer.name == "PS_Floor")
                {
                    Debug.Log($"[PersonalSpace][Geometry] {renderer.name} " +
                        $"center={renderer.bounds.center:F3} size={renderer.bounds.size:F3} " +
                        $"material={renderer.sharedMaterial?.name} " +
                        $"color={renderer.sharedMaterial?.color}");
                }
            }
            if (camera != null)
            {
                Debug.Log($"[PersonalSpace][Geometry] camera={camera.transform.position:F3} " +
                    $"forward={camera.transform.forward:F3} ambient={RenderSettings.ambientSkyColor}");
            }
        }

        internal static void PrepareRuntimePortrait(Camera camera, PersistentWorldMapController map)
        {
            // EditMode does not run these runtime initializers automatically.
            // Reuse them here, just as the existing idle-preview tool does.
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            UnityWorldLightingController lighting = camera.GetComponent<UnityWorldLightingController>();
            typeof(UnityWorldLightingController).GetMethod("Awake", flags)?.Invoke(lighting, null);
            UnityAvatarCommandReceiver receiver = camera.GetComponent<UnityAvatarCommandReceiver>();
            typeof(UnityAvatarCommandReceiver).GetMethod("Awake", flags)?.Invoke(receiver, null);
            Transform avatar = receiver.ActiveAvatarRoot;
            // The isolated Editor preview represents the local owner. Production
            // remains hidden until Flutter grants visibility; use that same
            // command here before LateUpdate applies the ownership mask. The
            // caller reloads the scene afterward and never saves this preview state.
            receiver.OnFlutterCommand(
                "{\"method\":\"setLocalAvatarVisible\",\"json\":\"{\\\"visible\\\":true}\"}");
            Vrm10Instance vrm = avatar != null ? avatar.GetComponentInChildren<Vrm10Instance>(true) : null;
            // Initialize the authored constraint rest state before posing bones.
            Vrm10Runtime vrmRuntime = vrm != null ? vrm.Runtime : null;
            typeof(UnityAvatarCommandReceiver).GetMethod("TryStartDesignedIdle", flags,
                null, Type.EmptyTypes, null)?.Invoke(receiver, null);
            Animator animator = avatar != null ? avatar.GetComponentInChildren<Animator>(true) : null;
            if (animator != null && animator.runtimeAnimatorController != null)
            {
                string idle = new SerializedObject(receiver)
                    .FindProperty("designedIdleStateName").stringValue;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.Rebind();
                int state = Animator.StringToHash(idle);
                for (int layer = 0; layer < animator.layerCount; layer++)
                {
                    if (animator.HasState(layer, state)) animator.Play(state, layer, 0.5f);
                }
                animator.Update(1f / 60f);
            }
            typeof(UnityAvatarCommandReceiver).GetMethod("LateUpdate", flags)?.Invoke(receiver, null);
            vrmRuntime?.Process();
            FrontFullBodyCamera framing = camera.GetComponent<FrontFullBodyCamera>();
            framing.TargetRoot = avatar;
            // Prefab instantiation in EditMode does not run Awake. Apply the
            // same state transition as EnsureRuntimeMap so the collision-only
            // fallback floor cannot z-fight with the authored oak boards.
            map.SetWorldActive(false);
            map.AlignHomeAvatar(avatar);
        }

        [MenuItem("Maaso/World/Build Cozy Personal Space")]
        public static void Build()
        {
            EnsureFolder("Assets/MaasoWorld", "PersonalSpace");
            EnsureFolder("Assets/MaasoWorld/PersonalSpace", "Models");
            ImportModel();

            if (AssetDatabase.LoadAssetAtPath<GameObject>(RuntimeModelPath) == null)
            {
                AssetDatabase.DeleteAsset(RuntimeModelPath);
            }

            GameObject modelAsset = AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath);
            if (modelAsset == null)
            {
                throw new FileNotFoundException(
                    "The Blender personal-space FBX is not imported.",
                    ModelPath);
            }

            Material whiteMaterial = EnsureWhiteMaterial();
            Scene scene = EditorSceneManager.NewScene(
                NewSceneSetup.EmptyScene,
                NewSceneMode.Single);
            SceneManager.SetActiveScene(scene);

            var sceneRoot = new GameObject(SceneRootName);
            sceneRoot.AddComponent<WorldEnvironmentController>();
            sceneRoot.AddComponent<WorldQualityController>();

            var environment = new GameObject(EnvironmentName);
            environment.transform.SetParent(sceneRoot.transform, false);

            GameObject model = PrefabUtility.InstantiatePrefab(
                modelAsset,
                scene) as GameObject;
            if (model == null)
            {
                throw new InvalidOperationException(
                    $"Unable to instantiate the imported personal-space model: {ModelPath}");
            }
            model.name = "PersonalSpaceModel";
            model.transform.SetParent(environment.transform, false);
            model.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.identity);
            model.transform.localScale = Vector3.one;
            // Keep the semantic root name across synchronous FBX reimports
            // while saving materials/previews. A plain assignment is not a
            // persistent override on the imported model's prefab instance.
            PrefabUtility.RecordPrefabInstancePropertyModifications(model);
            PrefabUtility.RecordPrefabInstancePropertyModifications(model.transform);
            ConfigureModel(model, whiteMaterial);
            Bounds modelBounds = CalculateBounds(model);
            ValidateModel(model, modelBounds);
            SaveRuntimeModel(model);

            var ground = new GameObject("PersonalSpaceGround");
            ground.transform.SetParent(environment.transform, false);
            ground.transform.localPosition = new Vector3(0f, -0.05f, 0f);
            BoxCollider groundCollider = ground.AddComponent<BoxCollider>();
            groundCollider.size = new Vector3(RoomSize, 0.1f, RoomSize);

            ConfigureSceneLighting();
            CoastalRoomV2Capture.CapturePreview(scene, model);

            if (!EditorSceneManager.SaveScene(scene, ScenePath))
            {
                throw new InvalidOperationException(
                    $"Unable to save the personal-space runtime scene at {ScenePath}.");
            }
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);

            Debug.Log(
                "[PersonalSpace][Build] generated authoring scene " +
                $"scene={ScenePath} renderers=" +
                $"{model.GetComponentsInChildren<Renderer>(true).Length} " +
                $"bounds={modelBounds.size}");
        }

        private static void ImportModel()
        {
            AssetDatabase.ImportAsset(
                ModelPath,
                ImportAssetOptions.ForceSynchronousImport |
                ImportAssetOptions.ForceUpdate);
            if (AssetImporter.GetAtPath(ModelPath) is not ModelImporter importer)
            {
                throw new InvalidOperationException(
                    $"The personal-space asset is not a model importer: {ModelPath}");
            }

            importer.globalScale = 1f;
            importer.useFileScale = true;
            importer.importAnimation = false;
            importer.importCameras = false;
            importer.importLights = false;
            importer.addCollider = false;
            importer.bakeAxisConversion = true;
            importer.generateSecondaryUV = false;
            importer.meshCompression = ModelImporterMeshCompression.Off;
            importer.importNormals = ModelImporterNormals.Import;
            // The Blender room owns its cream, oak, linen, and foliage palette.
            // Keep materials inside the model asset so prefab dependencies are
            // self-contained and no external material search can recolor it.
            importer.materialImportMode = ModelImporterMaterialImportMode.ImportStandard;
            importer.materialLocation = ModelImporterMaterialLocation.InPrefab;
            importer.SaveAndReimport();
        }

        private static Material EnsureWhiteMaterial()
        {
            Shader shader = Shader.Find("Universal Render Pipeline/Lit") ??
                Shader.Find("Standard");
            if (shader == null)
            {
                throw new InvalidOperationException(
                    "A supported lit shader is required for the personal-space white model.");
            }

            EnsureFolder("Assets/MaasoWorld", "Resources");
            Material material = AssetDatabase.LoadAssetAtPath<Material>(MaterialPath);
            if (material == null)
            {
                material = new Material(shader)
                {
                    name = "PersonalSpace White Model",
                    enableInstancing = true,
                };
                AssetDatabase.CreateAsset(material, MaterialPath);
            }
            Material runtimeMaterial = AssetDatabase.LoadAssetAtPath<Material>(
                RuntimeMaterialPath);
            if (runtimeMaterial == null)
            {
                runtimeMaterial = new Material(shader)
                {
                    name = "PersonalSpaceWhiteModel",
                    enableInstancing = true,
                };
                AssetDatabase.CreateAsset(runtimeMaterial, RuntimeMaterialPath);
            }

            foreach (Material target in new[] { material, runtimeMaterial })
            {
                target.shader = shader;
                target.enableInstancing = true;
                target.color = new Color(0.82f, 0.82f, 0.82f, 1f);
                if (target.HasProperty("_BaseColor"))
                {
                    target.SetColor("_BaseColor", target.color);
                }
                if (target.HasProperty("_Smoothness"))
                {
                    target.SetFloat("_Smoothness", 0.14f);
                }
                if (target.HasProperty("_Glossiness"))
                {
                    target.SetFloat("_Glossiness", 0.14f);
                }
                if (target.HasProperty("_Metallic"))
                {
                    target.SetFloat("_Metallic", 0f);
                }
                if (target.HasProperty("_GlossyReflections"))
                {
                    target.SetFloat("_GlossyReflections", 1f);
                    target.DisableKeyword("_GLOSSYREFLECTIONS_OFF");
                }
                if (target.HasProperty("_SpecularHighlights"))
                {
                    target.SetFloat("_SpecularHighlights", 1f);
                    target.DisableKeyword("_SPECULARHIGHLIGHTS_OFF");
                }
                EditorUtility.SetDirty(target);
            }
            return material;
        }

        public static void ConfigureModel(GameObject model, Material material)
        {
            // The bake manifest owns material bindings, UVs and display colors.
            // Keep this public seam for PersistentWorldMapBuilder callers.
            CoastalRoomV2Importer.ConfigureModel(model);
        }

        private static void SaveRuntimeModel(GameObject model)
        {
            EnsureFolder("Assets/MaasoWorld", "Resources");
            PrefabUtility.SaveAsPrefabAsset(model, RuntimeModelPath);
        }

        private static Bounds CalculateBounds(GameObject model)
        {
            Renderer[] renderers = model.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length == 0)
            {
                throw new InvalidOperationException(
                    "The personal-space model contains no renderers.");
            }

            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }

        private static void ValidateModel(GameObject model, Bounds bounds)
        {
            // The distant ocean card intentionally exceeds the interior bounds.
            CoastalRoomV2Importer.ValidateGeometry(model);
        }

        private static void ConfigureSceneLighting()
        {
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.50f, 0.48f, 0.44f);
            RenderSettings.ambientEquatorColor = new Color(0.38f, 0.35f, 0.30f);
            RenderSettings.ambientGroundColor = new Color(0.23f, 0.20f, 0.17f);
            RenderSettings.ambientIntensity = 0.80f;
            RenderSettings.reflectionIntensity = 0.18f;
            RenderSettings.skybox = null;
            RenderSettings.sun = null;
            RenderSettings.fog = false;
        }

        private static void RenderPreview(Scene scene, Bounds bounds)
        {
            var cameraObject = new GameObject("PersonalSpacePreviewCamera");
            var keyLightObject = new GameObject("PersonalSpacePreviewKeyLight");
            var fillLightObject = new GameObject("PersonalSpacePreviewFillLight");
            var rimLightObject = new GameObject("PersonalSpacePreviewRimLight");
            SceneManager.MoveGameObjectToScene(cameraObject, scene);
            SceneManager.MoveGameObjectToScene(keyLightObject, scene);
            SceneManager.MoveGameObjectToScene(fillLightObject, scene);
            SceneManager.MoveGameObjectToScene(rimLightObject, scene);

            RenderTexture target = null;
            Texture2D image = null;
            RenderTexture previousTarget = RenderTexture.active;
            try
            {
                Camera camera = cameraObject.AddComponent<Camera>();
                camera.orthographic = false;
                camera.fieldOfView = 35f;
                camera.aspect = 16f / 9f;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(0.78f, 0.79f, 0.80f, 1f);
                camera.allowHDR = true;
                camera.allowMSAA = true;
                camera.nearClipPlane = 0.1f;
                camera.farClipPlane = 60f;
                cameraObject.transform.position = new Vector3(0f, 1.55f, 3.1f);
                cameraObject.transform.rotation = Quaternion.LookRotation(
                    new Vector3(0f, 1.55f, -4.8f) - cameraObject.transform.position,
                    Vector3.up);

                Light keyLight = keyLightObject.AddComponent<Light>();
                keyLight.type = LightType.Directional;
                keyLight.renderMode = LightRenderMode.ForcePixel;
                keyLight.intensity = 1.05f;
                keyLight.color = new Color(1f, 0.985f, 0.965f);
                keyLight.shadows = LightShadows.Soft;
                keyLight.shadowStrength = 0.55f;
                keyLight.shadowBias = 0.025f;
                keyLight.shadowNormalBias = 0.18f;
                keyLight.shadowCustomResolution = 2048;
                keyLightObject.transform.rotation = Quaternion.Euler(50f, -35f, 0f);

                Light fillLight = fillLightObject.AddComponent<Light>();
                fillLight.type = LightType.Directional;
                fillLight.renderMode = LightRenderMode.ForcePixel;
                fillLight.intensity = 0.22f;
                fillLight.color = new Color(0.94f, 0.97f, 1f);
                fillLight.shadows = LightShadows.None;
                fillLightObject.transform.rotation = Quaternion.Euler(38f, 145f, 0f);

                Light rimLight = rimLightObject.AddComponent<Light>();
                rimLight.type = LightType.Directional;
                rimLight.renderMode = LightRenderMode.ForcePixel;
                rimLight.intensity = 0.10f;
                rimLight.color = Color.white;
                rimLight.shadows = LightShadows.None;
                rimLightObject.transform.rotation = Quaternion.Euler(68f, 15f, 0f);

                target = new RenderTexture(
                    PreviewSize,
                    PreviewSize * 9 / 16,
                    24,
                    RenderTextureFormat.ARGB32)
                {
                    antiAliasing = 4,
                    name = "PersonalSpacePreviewTarget",
                };
                target.Create();
                camera.targetTexture = target;
                camera.Render();

                RenderTexture.active = target;
                image = new Texture2D(
                    PreviewSize,
                    PreviewSize * 9 / 16,
                    TextureFormat.RGB24,
                    false);
                image.ReadPixels(
                    new Rect(0f, 0f, PreviewSize, PreviewSize * 9 / 16),
                    0,
                    0,
                    false);
                image.Apply(false, false);
                File.WriteAllBytes(
                    Path.GetFullPath(PreviewPath),
                    image.EncodeToPNG());
            }
            finally
            {
                RenderTexture.active = previousTarget;
                Camera previewCamera = cameraObject.GetComponent<Camera>();
                if (previewCamera != null)
                {
                    previewCamera.targetTexture = null;
                }
                if (target != null)
                {
                    target.Release();
                    Object.DestroyImmediate(target);
                }
                if (image != null)
                {
                    Object.DestroyImmediate(image);
                }
                Object.DestroyImmediate(cameraObject);
                Object.DestroyImmediate(keyLightObject);
                Object.DestroyImmediate(fillLightObject);
                Object.DestroyImmediate(rimLightObject);
            }
            AssetDatabase.ImportAsset(
                PreviewPath,
                ImportAssetOptions.ForceSynchronousImport |
                ImportAssetOptions.ForceUpdate);
        }

        private static void EnsureFolder(string parent, string name)
        {
            string path = $"{parent}/{name}";
            if (!AssetDatabase.IsValidFolder(path))
            {
                AssetDatabase.CreateFolder(parent, name);
            }
        }
    }
}
