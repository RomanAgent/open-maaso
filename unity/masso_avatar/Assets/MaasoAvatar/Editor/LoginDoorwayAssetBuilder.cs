using System;
using System.IO;
using System.Linq;
using Maaso.World;
using Maaso.World.Editor;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using UniVRM10;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Builds only the new articulated entrance; original room art is unchanged.</summary>
    public static class LoginDoorwayAssetBuilder
    {
        private const string ModelPath = "Assets/MaasoWorld/LoginDoorway/Models/LoginDoorway.fbx";
        private const string PrefabPath = "Assets/MaasoWorld/LoginDoorway/LoginDoorway.prefab";

        [MenuItem("Maaso/Avatar/Build Login Doorway")]
        public static void Build()
        {
            AssetDatabase.ImportAsset(ModelPath, ImportAssetOptions.ForceSynchronousImport);
            if (AssetImporter.GetAtPath(ModelPath) is ModelImporter importer)
            {
                importer.globalScale = 1f; importer.useFileScale = true;
                importer.importAnimation = false; importer.importCameras = false; importer.importLights = false;
                importer.importNormals = ModelImporterNormals.Calculate;
                importer.normalSmoothingAngle = 0;
                importer.bakeAxisConversion = true; importer.SaveAndReimport();
            }
            GameObject model = AssetDatabase.LoadAssetAtPath<GameObject>(ModelPath);
            if (model == null) throw new InvalidOperationException("Export the separate LoginDoorway.fbx first.");
            var root = new GameObject("LoginDoorway");
            try
            {
                LoginDoorwayRig rig = root.AddComponent<LoginDoorwayRig>();
                GameObject meshRoot = Object.Instantiate(model, root.transform);
                meshRoot.name = "AuthoredEntrance";
                Material white = Material("DoorwayWhite", new Color(.97f, .975f, .98f), .25f);
                Material metal = Material("DoorwayHardware", new Color(.19f, .21f, .23f), .75f);
                Material terracotta = Material("DoorwayMat", new Color(.49f, .23f, .13f), .03f);
                rig.DoorHinge = Anchor("DoorHinge", root.transform, new Vector3(2.985f, 0, 4.035f));
                foreach (Renderer renderer in meshRoot.GetComponentsInChildren<Renderer>(true))
                {
                    bool lever = renderer.name.Contains("Lever", StringComparison.Ordinal);
                    renderer.sharedMaterial = lever ? metal : white;
                    if (renderer.name == "V2_Entrance_Door" || renderer.name.StartsWith("V2_Entrance_DoorPanel", StringComparison.Ordinal) || lever)
                        renderer.transform.SetParent(rig.DoorHinge, true);
                    if (lever)
                    {
                        GameObject exteriorLever = Object.Instantiate(renderer.gameObject, rig.DoorHinge);
                        exteriorLever.name = "V2_Entrance_ExteriorLever";
                        exteriorLever.transform.position += new Vector3(0, 0, .19f);
                    }
                }
                Renderer leaf = rig.DoorHinge.GetComponentsInChildren<Renderer>(true)
                    .Single(renderer => renderer.name == "V2_Entrance_Door");
                if (Vector3.Distance(leaf.bounds.center, new Vector3(2.5f, 1.175f, 4.035f)) > .05f ||
                    Mathf.Abs(leaf.bounds.size.y - 2.35f) > .05f)
                    throw new InvalidOperationException("Door import no longer matches the source room opening.");
                Cube("DoorwayApron", root.transform, new Vector3(2.5f, -.025f, 5), new Vector3(3.2f, .05f, 2), white);
                Cube("DoorwayThreshold", root.transform, new Vector3(2.5f, .012f, 4.02f), new Vector3(1.07f, .024f, .22f), white);
                Cube("ExteriorWhiteWallLeft", root.transform, new Vector3(3.57f, 1.6f, 4.225f), new Vector3(1.06f, 3.2f, .05f), white);
                Cube("ExteriorWhiteWallRight", root.transform, new Vector3(1.45f, 1.6f, 4.225f), new Vector3(1.02f, 3.2f, .05f), white);
                Cube("ExteriorWhiteLintel", root.transform, new Vector3(2.5f, 2.8f, 4.225f), new Vector3(1.08f, .8f, .05f), white);
                Cube("WelcomeMat", root.transform, new Vector3(2.5f, .006f, 4.68f), new Vector3(.94f, .012f, .53f), terracotta);
                var lettering = new GameObject("WelcomeMatLettering");
                lettering.transform.SetParent(root.transform, false);
                lettering.transform.localPosition = new Vector3(2.5f, .014f, 4.68f);
                lettering.transform.localRotation = Quaternion.Euler(90, 180, 0);
                TextMesh text = lettering.AddComponent<TextMesh>();
                text.text = "WELCOME"; text.anchor = TextAnchor.MiddleCenter; text.alignment = TextAlignment.Center;
                text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
                text.fontSize = 48; text.characterSize = .021f; text.color = new Color(.92f, .87f, .72f);
                lettering.GetComponent<MeshRenderer>().sharedMaterial = text.font.material;
                rig.ExteriorCamera = Anchor("DoorwayExteriorCamera", root.transform, new Vector3(2.5f, 1.2f, 5.8f));
                rig.ThresholdCamera = Anchor("DoorwayThresholdCamera", root.transform, new Vector3(2.5f, 1.35f, 3.85f));
                rig.InteriorCamera = Anchor("DoorwayInteriorCamera", root.transform, new Vector3(1.45f, 1.35f, 2.5f));
                rig.DoorLookTarget = Anchor("DoorwayLookTarget", root.transform, new Vector3(2.5f, .25f, 4.03f));
                Transform fill = Anchor("ExteriorDoorwayFill", root.transform, new Vector3(2.5f, 2.8f, 5.8f));
                fill.LookAt(new Vector3(2.5f, 1.1f, 4.03f));
                Light exteriorLight = fill.gameObject.AddComponent<Light>();
                exteriorLight.type = LightType.Spot; exteriorLight.color = Color.white;
                exteriorLight.spotAngle = 100; exteriorLight.range = 4; exteriorLight.intensity = 1.2f;
                exteriorLight.shadows = LightShadows.Soft;
                if (!rig.IsReady) throw new InvalidOperationException("Doorway rig is incomplete.");
                int layer = LayerMask.NameToLayer("PersonalSpaceEnvironment");
                if (layer < 0) throw new InvalidOperationException("Home environment layer is missing.");
                foreach (Transform child in root.GetComponentsInChildren<Transform>(true)) child.gameObject.layer = layer;
                PrefabUtility.SaveAsPrefabAsset(root, PrefabPath);
                AssetDatabase.SaveAssets();
                Debug.Log("[LoginDoorway] Built " + PrefabPath);
            }
            finally { Object.DestroyImmediate(root); }
        }

        [MenuItem("Maaso/Avatar/Capture Login Doorway")]
        public static void Capture()
        {
            const string companion = "Assets/MaasoAvatar/Scenes/Companion.unity";
            Scene scene = EditorSceneManager.OpenScene(companion, OpenSceneMode.Single);
            Camera camera = scene.GetRootGameObjects().SelectMany(root => root.GetComponentsInChildren<Camera>(true))
                .Single(value => value.CompareTag("MainCamera"));
            GameObject mapAsset = Resources.Load<GameObject>(PersistentWorldMapController.ResourceName);
            GameObject mapRoot = PrefabUtility.InstantiatePrefab(mapAsset, scene) as GameObject;
            if (mapRoot == null) throw new InvalidOperationException("Home room is unavailable.");
            RenderTexture target = null;
            var previousTarget = RenderTexture.active;
            string rootPath = Path.GetFullPath(Path.Combine(Application.dataPath, "../../.."));
            string evidence = Path.Combine(rootPath, "docs/verification/2026-09-22-product-resume/login-doorway-v4");
            Directory.CreateDirectory(evidence);
            try
            {
                var map = mapRoot.GetComponent<PersistentWorldMapController>();
                PersonalSpaceSceneBuilder.PrepareRuntimePortrait(camera, map);
                ResetPreviewMouth(camera.GetComponent<UnityAvatarCommandReceiver>());
                var framing = camera.GetComponent<FrontFullBodyCamera>();
                framing.SetHomeViewReference(map.HomeCameraReference);
                framing.FrameNow();
                LoginDoorwayRig rig = LoginDoorwayRig.Ensure(map);
                if (rig == null) throw new InvalidOperationException("Publish the reviewed room with a shared entry before capture.");
                target = new RenderTexture(900, 1950, 24, RenderTextureFormat.ARGB32) { antiAliasing = 4 };
                target.Create(); camera.targetTexture = target; camera.aspect = 900f / 1950f;
                var controller = new LoginDoorwayTransitionController(result =>
                {
                    if (!result.ok) throw new InvalidOperationException(result.code);
                });
                long utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                int sequence = 0;
                void Phase(string phase, int duration, float now) => controller.Execute(new LoginDoorwayCommand
                {
                    requestId = "capture-" + phase, transitionId = "capture-doorway", phase = phase,
                    durationMs = duration, sequence = ++sequence, expiresAtMs = utc + 60000,
                }, framing, rig, true, now, utc);
                Phase("prepare", 0, 0);
                SaveFrame(camera, target, Path.Combine(evidence, "01-closed.png"));
                string posterPath = Path.Combine(rootPath, "assets/brand/login_doorway.png");
                SaveFrame(camera, target, posterPath, poster: true);
                Phase("open", 650, 0);
                controller.Advance(.325f, utc); SaveFrame(camera, target, Path.Combine(evidence, "02-opening.png"));
                controller.Advance(.65f, utc); SaveFrame(camera, target, Path.Combine(evidence, "03-open.png"));
                Phase("enter", 1200, .65f);
                controller.Advance(1.25f, utc); SaveFrame(camera, target, Path.Combine(evidence, "04-entering.png"));
                controller.Advance(1.86f, utc); SaveFrame(camera, target, Path.Combine(evidence, "05-inside.png"));
                Phase("frame", 300, 1.86f);
                for(int frame=1;frame<=900&&controller.OwnsCamera;frame++)
                {
                    rig.Navigation?.BedroomDoor?.Advance(1f/60);
                    controller.Advance(1.86f+frame/60f,utc+frame*1000/60);
                }
                if(controller.OwnsCamera)throw new InvalidOperationException("Doorway framing did not reach the actual Avatar.");
                SaveFrame(camera, target, Path.Combine(evidence, "06-avatar.png"));
                File.WriteAllText(Path.Combine(evidence, "capture.txt"),
                    "Source: actual Companion scene + published V4 PersonalSpaceMap; the scene-bound room entry is the sole login door.\n" +
                    "Pose: current built-in avatar; no second room or avatar.\n" +
                    "Mouth: existing neutral/TTS reset, then actual current CPU BakeMesh skin for synchronous Editor capture; not a player GPU or live-TTS validation. No model asset edited.\n" +
                    "Poster: exact prepare camera crop from this capture.\n");
            }
            finally
            {
                camera.targetTexture = null; RenderTexture.active = previousTarget;
                if (target != null) { target.Release(); Object.DestroyImmediate(target); }
                Object.DestroyImmediate(mapRoot);
                // Never save preview actors, camera changes, or scene instances.
                EditorSceneManager.OpenScene(companion, OpenSceneMode.Single);
            }
        }

        internal static void SaveFrame(Camera camera, RenderTexture target, string path, bool poster = false)
        {
            int height = poster ? Mathf.RoundToInt(target.height * .48f) : target.height;
            var image = new Texture2D(target.width, height, TextureFormat.RGB24, false);
            var snapshots = new System.Collections.Generic.List<GameObject>();
            var meshes = new System.Collections.Generic.List<Mesh>();
            var visibility = new System.Collections.Generic.Dictionary<SkinnedMeshRenderer, bool>();
            try
            {
                // Match the existing Joy scene/vowel diagnostics. Camera.Render
                // alone can reuse an older GPU skin within one Editor method.
                Transform avatar = camera.GetComponent<UnityAvatarCommandReceiver>()?.ActiveAvatarRoot;
                if (avatar != null)
                foreach (SkinnedMeshRenderer source in avatar.GetComponentsInChildren<SkinnedMeshRenderer>(false))
                {
                    if (!source.enabled || source.forceRenderingOff || source.sharedMesh == null) continue;
                    var mesh = new Mesh { name = source.name + "_DoorwayCpuSkin" };
                    meshes.Add(mesh); source.BakeMesh(mesh);
                    var snapshot = new GameObject(source.name + "_DoorwayPreviewSkin")
                    { hideFlags = HideFlags.HideAndDontSave, layer = source.gameObject.layer };
                    snapshots.Add(snapshot); snapshot.transform.SetParent(source.transform, false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer renderer = snapshot.AddComponent<MeshRenderer>();
                    renderer.sharedMaterials = source.sharedMaterials;
                    renderer.shadowCastingMode = source.shadowCastingMode; renderer.receiveShadows = source.receiveShadows;
                    renderer.lightProbeUsage = source.lightProbeUsage; renderer.reflectionProbeUsage = source.reflectionProbeUsage;
                    visibility[source] = source.forceRenderingOff; source.forceRenderingOff = true;
                }
                camera.Render(); RenderTexture.active = target;
                image.ReadPixels(new Rect(0, poster ? target.height - height : 0, target.width, height), 0, 0); image.Apply();
                Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllBytes(path, image.EncodeToPNG());
            }
            finally
            {
                foreach (var source in visibility) source.Key.forceRenderingOff = source.Value;
                foreach (GameObject snapshot in snapshots) Object.DestroyImmediate(snapshot);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                Object.DestroyImmediate(image);
            }
        }

        internal static void ResetPreviewMouth(UnityAvatarCommandReceiver receiver)
        {
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            typeof(UnityAvatarCommandReceiver).GetMethod("ResetExpressionTransition", flags)?.Invoke(receiver, null);
            receiver.OnFlutterCommand("{\"method\":\"stopLipSync\",\"json\":\"{}\"}");
            receiver.OnFlutterCommand("{\"method\":\"setMouthOpen\",\"json\":\"{\\\"value\\\":0}\"}");
            typeof(UnityAvatarCommandReceiver).GetMethod("LateUpdate", flags)?.Invoke(receiver, null);
            receiver.ActiveAvatarRoot?.GetComponentInChildren<Vrm10Instance>(true)?.Runtime.Process();
        }

        private static Transform Anchor(string name, Transform parent, Vector3 position)
        {
            var child = new GameObject(name); child.transform.SetParent(parent, false); child.transform.localPosition = position; return child.transform;
        }
        private static void Cube(string name, Transform parent, Vector3 position, Vector3 scale, Material material)
        {
            GameObject cube = GameObject.CreatePrimitive(PrimitiveType.Cube); cube.name = name;
            cube.transform.SetParent(parent, false); cube.transform.localPosition = position; cube.transform.localScale = scale;
            Object.DestroyImmediate(cube.GetComponent<Collider>()); cube.GetComponent<Renderer>().sharedMaterial = material;
        }
        private static Material Material(string name, Color color, float smoothness)
        {
            string directory = "Assets/MaasoWorld/LoginDoorway/Materials";
            Directory.CreateDirectory(directory); AssetDatabase.Refresh();
            string path = directory + "/" + name + ".mat";
            Material material = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (material == null) { material = new Material(Shader.Find("Standard")); AssetDatabase.CreateAsset(material, path); }
            material.color = color; material.SetFloat("_Glossiness", smoothness); EditorUtility.SetDirty(material); return material;
        }
    }
}
