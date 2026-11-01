#if UNITY_EDITOR
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Samples the installed Joy through the real timeline, LateUpdate jaw
    /// ownership and VRM expression passes. CPU BakeMesh includes all resulting
    /// bones AND morphs; temporary static meshes avoid stale synchronous Editor
    /// GPU skinning. This is a reproducible geometry/render audit, not live TTS.
    /// </summary>
    public static class JoyVowelGeometryDiagnostic
    {
        private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
        private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
        private static readonly ExpressionKey[] Vowels =
            { ExpressionKey.Aa, ExpressionKey.Ee, ExpressionKey.Ih, ExpressionKey.Oh, ExpressionKey.Ou };
        private static readonly string[] CueNames = { "aa", "ee", "ih", "oh", "ou" };
        private static readonly string[] Labels = { "A", "E", "I", "O", "U" };

        [Serializable] private sealed class Command { public string method, json; }
        [Serializable] private sealed class Sample
        {
            public string label, cue;
            public float[] actualVowels;
            public float maxVertexDeltaMeters, jawErrorDegrees;
            public int changedVertices;
        }
        [Serializable] private sealed class Pair
        { public string first, second; public float maximumMeters; }
        [Serializable] private sealed class Capture
        {
            public string path, sha256, view;
            public Vector3 cameraPosition, cameraEuler;
            public float orthographicSize, luminanceRange;
        }
        [Serializable] private sealed class Report
        {
            public bool passed;
            public string failure, vrmSha256, sceneSha256Before, sceneSha256After, prefabPath;
            public string method = "Saved Companion prefab -> OnFlutterCommand(startVisemeTimeline) -> receiver LateUpdate (jaw ownership retained) -> VRM.Runtime.Process -> SkinnedMeshRenderer.BakeMesh. Fixed neutral-camera transforms and identical real materials/light for all vowels. Synthetic clock samples, not player GPU or end-to-end live speech.";
            public List<Sample> samples = new();
            public List<Pair> pairwise = new();
            public List<Capture> captures = new();
        }

        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_VOWEL_AUDIT") ?? "/tmp/maaso-joy-vowels";
            Directory.CreateDirectory(output);
            var report = new Report { vrmSha256 = Hash(ModelPath), sceneSha256Before = Hash(ScenePath) };
            GameObject cameraObject = null, lightObject = null;
            bool opened = false;
            try
            {
                var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                opened = true;
                var receiver = Object.FindFirstObjectByType<UnityAvatarCommandReceiver>();
                Require(receiver != null, "The saved scene must contain the production receiver.");
                Invoke(receiver, "Awake");
                Transform root = receiver.ActiveAvatarRoot;
                Require(root != null, "The receiver must bind the installed avatar.");
                // EditMode has no Flutter presence owner to grant visibility.
                // Match PersonalSpaceSceneBuilder's temporary preview command;
                // keep the production default-hidden gate and renderer flags intact.
                Send(receiver, "setLocalAvatarVisible", "{\"visible\":true}");
                report.prefabPath = PrefabUtility.GetPrefabAssetPathOfNearestInstanceRoot(root.gameObject);
                Require(report.prefabPath == ModelPath, "The diagnostic must use the saved Joy prefab.");
                var vrm = root.GetComponentInChildren<Vrm10Instance>(true);
                var animator = root.GetComponentInChildren<Animator>(true);
                Require(vrm != null && animator != null && animator.avatar != null && animator.avatar.isHuman,
                    "The saved Joy must retain its VRM and Humanoid animator.");
                Require(vrm.TryGetBoneTransform(HumanBodyBones.Jaw, out Transform jaw), "Joy must have its raw jaw.");
                var initPose = (IDictionary)vrm.Runtime.GetType().GetProperty("InitPose").GetValue(vrm.Runtime);
                object jawImport = initPose[jaw];
                Quaternion rest = (Quaternion)jawImport.GetType().GetProperty("LocalRotation").GetValue(jawImport);
                SkinnedMeshRenderer face = root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                    .Single(renderer => renderer.sharedMesh != null && renderer.sharedMesh.GetBlendShapeIndex("Smile_L") >= 0);
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.applyRootMotion = false;
                animator.Rebind();
                animator.Play("idle_shrug", 0, 0f);
                animator.Update(0f);
                SetField(receiver, "autoBlink", false);
                SetField(receiver, "actionPoseHoldUntil", Time.realtimeSinceStartup + 3600f);
                Send(receiver, "setExpression", "{\"eyeOpen\":1}");
                Invoke(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
                Process(receiver, vrm);
                Vector3[] neutral = BakeFace(face);

                // Cameras derive from the neutral eye position once. Subsequent
                // vowels cannot hide motion by changing the crop or viewpoint.
                Vector3 focus = (animator.GetBoneTransform(HumanBodyBones.LeftEye).position +
                    animator.GetBoneTransform(HumanBodyBones.RightEye).position) * .5f - root.up * .035f;
                Vector3[] positions = { focus + root.forward * .75f, focus + root.right * .75f };
                Quaternion[] rotations = positions.Select(position => Quaternion.LookRotation(focus - position, root.up)).ToArray();
                cameraObject = new GameObject("JoyVowelTemporaryCamera") { hideFlags = HideFlags.HideAndDontSave };
                Camera camera = cameraObject.AddComponent<Camera>();
                camera.enabled = false;
                camera.scene = scene;
                camera.orthographic = true;
                camera.orthographicSize = .175f;
                camera.aspect = 1f;
                camera.nearClipPlane = .01f;
                camera.farClipPlane = 5f;
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(.94f, .94f, .94f);
                var usedLayers = new HashSet<int>(Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include)
                    .Select(renderer => renderer.gameObject.layer));
                int isolatedLayer = Enumerable.Range(8, 23).Reverse().FirstOrDefault(layer => !usedLayers.Contains(layer));
                Require(isolatedLayer >= 8, "A free layer is required to isolate temporary avatar snapshots.");
                camera.cullingMask = 1 << isolatedLayer;
                foreach (Light light in Object.FindObjectsByType<Light>()) light.enabled = false;
                RenderSettings.ambientMode = AmbientMode.Flat;
                RenderSettings.ambientLight = new Color(.62f, .62f, .62f);
                lightObject = new GameObject("JoyVowelTemporaryKey") { hideFlags = HideFlags.HideAndDontSave };
                Light keyLight = lightObject.AddComponent<Light>();
                keyLight.type = LightType.Directional;
                keyLight.intensity = 1.1f;
                keyLight.shadows = LightShadows.Soft;
                keyLight.transform.rotation = root.rotation * Quaternion.Euler(35f, -25f, 0f);

                RecordSample(report, "neutral", "sil", vrm, face, jaw, rest, neutral);
                CaptureViews(camera, root, isolatedLayer, output, "neutral", positions, rotations, report);
                var geometries = new List<Vector3[]>();
                for (int index = 0; index < CueNames.Length; index++)
                {
                    Send(receiver, "startVisemeTimeline", "{\"format\":\"vrm_viseme_v2\",\"envelope\":[0.6,0.6,0,0]," +
                        "\"cues\":[{\"frame\":0,\"viseme\":\"" + CueNames[index] + "\"}],\"frameRate\":1}");
                    ProcessTimelineFrame(receiver, vrm, 0);
                    Sample sample = RecordSample(report, Labels[index], CueNames[index], vrm, face, jaw, rest, neutral);
                    Require(sample.actualVowels[index] > .5f, Labels[index] + " must reach the actual VRM output.");
                    Require(sample.actualVowels.Where((_, other) => other != index).All(value => value == 0f),
                        Labels[index] + " must not collapse to a different vowel.");
                    Require(sample.maxVertexDeltaMeters > .0003f, Labels[index] + " needs visible real mesh deformation.");
                    geometries.Add(BakeFace(face));
                    CaptureViews(camera, root, isolatedLayer, output, Labels[index] + "_" + CueNames[index], positions, rotations, report);
                    ProcessTimelineFrame(receiver, vrm, 2);
                    Sample silent = RecordSample(report, "silence_after_" + Labels[index], CueNames[index], vrm, face, jaw, rest, neutral);
                    Require(silent.actualVowels.All(value => value == 0f) && silent.maxVertexDeltaMeters < .00001f,
                        Labels[index] + " zero energy must restore the actual neutral geometry.");
                }
                for (int first = 0; first < geometries.Count; first++)
                    for (int second = first + 1; second < geometries.Count; second++)
                    {
                        float difference = MaximumDelta(geometries[first], geometries[second]);
                        report.pairwise.Add(new Pair { first = Labels[first], second = Labels[second], maximumMeters = difference });
                        Require(difference > .0003f, Labels[first] + "/" + Labels[second] + " must have distinct baked mouth shapes.");
                    }
                Send(receiver, "stopLipSync", "{}");
                Process(receiver, vrm);
                Sample stopped = RecordSample(report, "stopped", "sil", vrm, face, jaw, rest, neutral);
                Require(stopped.actualVowels.All(value => value == 0f) && stopped.maxVertexDeltaMeters < .00001f,
                    "stopLipSync must restore the original mouth geometry.");
                CaptureViews(camera, root, isolatedLayer, output, "stopped", positions, rotations, report);
                report.passed = true;
            }
            catch (Exception error)
            {
                report.failure = error.ToString();
                throw;
            }
            finally
            {
                if (cameraObject != null) Object.DestroyImmediate(cameraObject);
                if (lightObject != null) Object.DestroyImmediate(lightObject);
                if (opened) EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                report.sceneSha256After = Hash(ScenePath);
                if (report.sceneSha256Before != report.sceneSha256After)
                {
                    report.passed = false;
                    report.failure = (report.failure ?? "") + " Saved scene changed during a read-only audit.";
                }
                File.WriteAllText(Path.Combine(output, "vowel-geometry.json"), JsonUtility.ToJson(report, true));
                Debug.Log("[JoyVowelGeometryDiagnostic] passed=" + report.passed + " output=" + output);
            }
        }

        private static Sample RecordSample(Report report, string label, string cue, Vrm10Instance vrm,
            SkinnedMeshRenderer face, Transform jaw, Quaternion rest, Vector3[] neutral)
        {
            Vector3[] current = BakeFace(face);
            Require(current.Length == neutral.Length && current.Length > 0, "Baked face vertex identity must stay stable.");
            var sample = new Sample { label = label, cue = cue,
                actualVowels = Vowels.Select(vowel => vrm.Runtime.Expression.ActualWeights[vowel]).ToArray(),
                maxVertexDeltaMeters = MaximumDelta(neutral, current),
                changedVertices = neutral.Zip(current, Vector3.Distance).Count(distance => distance > .00001f),
                jawErrorDegrees = Quaternion.Angle(jaw.localRotation, rest) };
            report.samples.Add(sample);
            Require(sample.jawErrorDegrees < .05f, label + " must preserve the imported jaw neutral pose.");
            return sample;
        }

        private static Vector3[] BakeFace(SkinnedMeshRenderer face)
        {
            var mesh = new Mesh();
            try { face.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }

        private static float MaximumDelta(Vector3[] first, Vector3[] second)
        {
            Require(first.Length == second.Length && first.Length > 0, "Geometry arrays must match.");
            float result = 0f;
            for (int index = 0; index < first.Length; index++)
            {
                float distance = Vector3.Distance(first[index], second[index]);
                Require(!float.IsNaN(distance) && !float.IsInfinity(distance), "Baked geometry must stay finite.");
                result = Mathf.Max(result, distance);
            }
            return result;
        }

        private static void CaptureViews(Camera camera, Transform root, int layer, string output, string name,
            Vector3[] positions, Quaternion[] rotations, Report report)
        {
            var objects = new List<GameObject>();
            var meshes = new List<Mesh>();
            try
            {
                foreach (SkinnedMeshRenderer source in root.GetComponentsInChildren<SkinnedMeshRenderer>(false))
                {
                    if (!source.enabled || source.forceRenderingOff || source.sharedMesh == null) continue;
                    var mesh = new Mesh { name = source.name + "_VowelCpuSkin" };
                    meshes.Add(mesh);
                    source.BakeMesh(mesh);
                    var snapshot = new GameObject(source.name + "_VowelSnapshot")
                        { hideFlags = HideFlags.HideAndDontSave, layer = layer };
                    objects.Add(snapshot);
                    snapshot.transform.SetParent(source.transform, false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                    var renderer = snapshot.AddComponent<MeshRenderer>();
                    renderer.sharedMaterials = source.sharedMaterials;
                    renderer.shadowCastingMode = source.shadowCastingMode;
                    renderer.receiveShadows = source.receiveShadows;
                }
                Require(objects.Count > 0, "Capture must contain actual morph-aware baked skins.");
                string[] views = { "front", "side" };
                for (int index = 0; index < views.Length; index++)
                {
                    camera.transform.SetPositionAndRotation(positions[index], rotations[index]);
                    CaptureImage(camera, Path.Combine(output, name + "_" + views[index] + ".png"), views[index], report);
                }
            }
            finally
            {
                foreach (GameObject value in objects) Object.DestroyImmediate(value);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
            }
        }

        private static void CaptureImage(Camera camera, string path, string view, Report report)
        {
            const int size = 1024;
            var target = new RenderTexture(size, size, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB)
                { antiAliasing = 4 };
            var pixels = new Texture2D(size, size, TextureFormat.RGB24, false, false);
            RenderTexture previousActive = RenderTexture.active, previousTarget = camera.targetTexture;
            try
            {
                target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, size, size), 0, 0); pixels.Apply();
                float minimum = 1f, maximum = 0f;
                Color32[] colors = pixels.GetPixels32();
                for (int index = 0; index < colors.Length; index += 97)
                {
                    Color32 pixel = colors[index];
                    float luminance = (.2126f * pixel.r + .7152f * pixel.g + .0722f * pixel.b) / 255f;
                    minimum = Mathf.Min(minimum, luminance); maximum = Mathf.Max(maximum, luminance);
                }
                File.WriteAllBytes(path, pixels.EncodeToPNG());
                report.captures.Add(new Capture { path = path, sha256 = Hash(path), view = view,
                    cameraPosition = camera.transform.position, cameraEuler = camera.transform.eulerAngles,
                    orthographicSize = camera.orthographicSize, luminanceRange = maximum - minimum });
                Require(maximum - minimum > .05f, "The " + view + " capture must not be blank.");
            }
            finally
            {
                camera.targetTexture = previousTarget; RenderTexture.active = previousActive;
                target.Release(); Object.DestroyImmediate(target); Object.DestroyImmediate(pixels);
            }
        }

        private static void ProcessTimelineFrame(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm, int frame)
        {
            SetField(receiver, "lipSyncStartedAt", Time.realtimeSinceStartup - frame - .1f);
            Process(receiver, vrm);
        }
        private static void Process(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm)
        { Invoke(receiver, "LateUpdate"); vrm.Runtime.Process(); }
        private static void Send(UnityAvatarCommandReceiver receiver, string method, string json) =>
            receiver.OnFlutterCommand(JsonUtility.ToJson(new Command { method = method, json = json }));
        private static void Invoke(object target, string method, params object[] arguments)
        {
            try { target.GetType().GetMethod(method, PrivateInstance).Invoke(target, arguments); }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
        }
        private static void SetField(object target, string name, object value) =>
            target.GetType().GetField(name, PrivateInstance).SetValue(target, value);
        private static void Require(bool condition, string reason)
        { if (!condition) throw new InvalidOperationException(reason); }
        private static string Hash(string path)
        {
            using var algorithm = SHA256.Create();
            using var stream = File.OpenRead(path);
            return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
    }
}
#endif
