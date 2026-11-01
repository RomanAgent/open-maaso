#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using UniVRM10;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Read-only, same-pose CPU-skinned Home eye comparison. No scene,
    /// model, material or lighting assets are saved by this diagnostic.</summary>
    public static class HomeEyeContactDiagnostic
    {
        private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
        private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const BindingFlags Flags = BindingFlags.NonPublic | BindingFlags.Instance;
        [Serializable] private sealed class Command { public string method, json; }
        [Serializable] private sealed class MeshDelta { public string mesh; public float maxMeters; public int changedVertices; }
        [Serializable] private sealed class Report
        {
            public bool passed;
            public string failure, modelSha256, sceneBefore, sceneAfter;
            public string method = "Saved Companion -> receiver LateUpdate -> VRM.Runtime.Process -> CPU BakeMesh. Fixed neutral pose, same original scene lighting/materials and fixed camera; isolated white background, 1024px, MSAA4. Not a live device screenshot.";
            public float beforePitch, afterPitch, leftEyeDegrees, rightEyeDegrees, headDegrees, rootDegrees, headMeters, rootMeters;
            public Vector3 cameraPosition, cameraEuler;
            public List<MeshDelta> meshDeltas = new();
            public string beforeImage, afterImage;
            public string diagnosticFillBeforeImage, diagnosticFillAfterImage;
            public string diagnosticFillNote = "DIAGNOSTIC ONLY: additional fixed frontal white directional fill, intensity 1.25, no shadows, isolated snapshot layer only. Same fill for both images. Original materials and scene lights are unchanged; this is not the shipped Home lighting.";
            public Vector3 diagnosticFillEuler;
        }

        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_HOME_EYE_AUDIT") ?? "/tmp/maaso-home-eye-contact";
            Directory.CreateDirectory(output);
            var report = new Report { modelSha256 = Hash(ModelPath), sceneBefore = Hash(ScenePath) };
            GameObject cameraObject = null, diagnosticFillObject = null;
            try
            {
                var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                var receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                Require(receiver != null, "Production receiver missing.");
                Invoke(receiver, "Awake");
                Send(receiver, "setLocalAvatarVisible", "{\"visible\":true}");
                Transform root = receiver.ActiveAvatarRoot;
                var vrm = root.GetComponentInChildren<Vrm10Instance>(true);
                var animator = root.GetComponentInChildren<Animator>(true);
                var framing = Object.FindAnyObjectByType<FrontFullBodyCamera>();
                Require(vrm != null && animator != null && framing != null && framing.TargetRoot == root,
                    "Installed Home avatar and camera must be bound.");
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.applyRootMotion = false;
                animator.Rebind(); animator.Play("idle_shrug", 0, 0f); animator.Update(0f);
                Set(receiver, "autoBlink", false);
                Set(receiver, "actionPoseHoldUntil", Time.realtimeSinceStartup + 3600f);
                Send(receiver, "setExpression", "{\"eyeOpen\":1}");
                Invoke(receiver, "UpdateExpressionTransition", Time.realtimeSinceStartup + 1f);
                framing.enabled = false;
                Process(receiver, vrm);
                framing.enabled = true;
                report.beforePitch = vrm.Runtime.LookAt.Pitch;
                Require(Mathf.Abs(report.beforePitch) < .001f, "Before must be the previous uncalibrated eye center.");
                Transform left = animator.GetBoneTransform(HumanBodyBones.LeftEye), right = animator.GetBoneTransform(HumanBodyBones.RightEye),
                    head = animator.GetBoneTransform(HumanBodyBones.Head);
                Quaternion leftBefore = left.rotation, rightBefore = right.rotation, headBefore = head.rotation, rootBefore = root.rotation;
                Vector3 headPosition = head.position, rootPosition = root.position;
                SkinnedMeshRenderer[] skins = root.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                var beforeMeshes = skins.ToDictionary(skin => skin, Bake);

                Vector3 focus = (left.position + right.position) * .5f - root.up * .035f;
                cameraObject = new GameObject("HomeEyeReadOnlyCamera") { hideFlags = HideFlags.HideAndDontSave };
                Camera camera = cameraObject.AddComponent<Camera>();
                camera.enabled = false; camera.scene = scene; camera.orthographic = true;
                camera.orthographicSize = .175f; camera.aspect = 1f; camera.nearClipPlane = .01f; camera.farClipPlane = 5f;
                camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = Color.white;
                camera.transform.SetPositionAndRotation(focus + root.forward * .75f,
                    Quaternion.LookRotation(-root.forward, root.up));
                report.cameraPosition = camera.transform.position; report.cameraEuler = camera.transform.eulerAngles;
                var used = new HashSet<int>(Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include)
                    .Select(renderer => renderer.gameObject.layer));
                int layer = Enumerable.Range(8, 23).Reverse().FirstOrDefault(value => !used.Contains(value));
                Require(layer >= 8, "No free snapshot isolation layer."); camera.cullingMask = 1 << layer;
                diagnosticFillObject = new GameObject("HomeEye_DIAGNOSTIC_ONLY_FrontalFill")
                    { hideFlags = HideFlags.HideAndDontSave };
                Light diagnosticFill = diagnosticFillObject.AddComponent<Light>();
                diagnosticFill.enabled = false;
                diagnosticFill.type = LightType.Directional;
                diagnosticFill.color = Color.white;
                diagnosticFill.intensity = 1.25f;
                diagnosticFill.shadows = LightShadows.None;
                diagnosticFill.cullingMask = 1 << layer;
                diagnosticFill.transform.rotation = camera.transform.rotation;
                report.diagnosticFillEuler = diagnosticFill.transform.eulerAngles;
                report.beforeImage = Path.Combine(output, "home-eyes-before.png");
                Capture(camera, root, layer, report.beforeImage);
                report.diagnosticFillBeforeImage = Path.Combine(output, "home-eyes-before-diagnostic-frontal-fill.png");
                diagnosticFill.enabled = true;
                Capture(camera, root, layer, report.diagnosticFillBeforeImage);
                diagnosticFill.enabled = false;
                Process(receiver, vrm);
                report.afterPitch = vrm.Runtime.LookAt.Pitch;
                report.leftEyeDegrees = Quaternion.Angle(leftBefore, left.rotation);
                report.rightEyeDegrees = Quaternion.Angle(rightBefore, right.rotation);
                report.headDegrees = Quaternion.Angle(headBefore, head.rotation);
                report.rootDegrees = Quaternion.Angle(rootBefore, root.rotation);
                report.headMeters = Vector3.Distance(headPosition, head.position);
                report.rootMeters = Vector3.Distance(rootPosition, root.position);
                Require(report.afterPitch < -1f && report.leftEyeDegrees > 1f && report.leftEyeDegrees < 4f &&
                    report.rightEyeDegrees > 1f && report.rightEyeDegrees < 4f, "Home must rotate both eyes slightly downward.");
                Require(report.headDegrees < .03f && report.rootDegrees < .01f && report.headMeters < .00001f && report.rootMeters < .00001f,
                    "Fixed eye contact must not move the head or body.");
                foreach (var pair in beforeMeshes)
                {
                    Vector3[] after = Bake(pair.Key);
                    var delta = new MeshDelta { mesh = pair.Key.name };
                    Require(after.Length == pair.Value.Length, "Mesh vertex identity changed.");
                    for (int vertex = 0; vertex < after.Length; vertex++)
                    {
                        float distance = Vector3.Distance(pair.Value[vertex], after[vertex]);
                        delta.maxMeters = Mathf.Max(delta.maxMeters, distance);
                        if (distance > .00001f) delta.changedVertices++;
                    }
                    report.meshDeltas.Add(delta);
                }
                Require(report.meshDeltas.Any(delta => delta.changedVertices > 10 && delta.maxMeters > .0001f),
                    "Actual CPU skinned eye geometry must change; LookAt input alone is insufficient.");
                report.afterImage = Path.Combine(output, "home-eyes-after.png");
                Capture(camera, root, layer, report.afterImage);
                report.diagnosticFillAfterImage = Path.Combine(output, "home-eyes-after-diagnostic-frontal-fill.png");
                diagnosticFill.enabled = true;
                Capture(camera, root, layer, report.diagnosticFillAfterImage);
                diagnosticFill.enabled = false;
                report.passed = true;
            }
            catch (Exception error) { report.failure = error.ToString(); throw; }
            finally
            {
                if (cameraObject != null) Object.DestroyImmediate(cameraObject);
                if (diagnosticFillObject != null) Object.DestroyImmediate(diagnosticFillObject);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                report.sceneAfter = Hash(ScenePath);
                if (report.sceneBefore != report.sceneAfter) { report.passed = false; report.failure = "Saved scene changed."; }
                File.WriteAllText(Path.Combine(output, "home-eye-contact.json"), JsonUtility.ToJson(report, true));
                Debug.Log("[HomeEyeContactDiagnostic] passed=" + report.passed + " output=" + output);
            }
        }

        private static Vector3[] Bake(SkinnedMeshRenderer skin)
        {
            var mesh = new Mesh();
            try { skin.BakeMesh(mesh); return mesh.vertices; }
            finally { Object.DestroyImmediate(mesh); }
        }
        private static void Capture(Camera camera, Transform root, int layer, string path)
        {
            var snapshots = new List<GameObject>(); var meshes = new List<Mesh>();
            var target = new RenderTexture(1024, 1024, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB) { antiAliasing = 4 };
            var pixels = new Texture2D(1024, 1024, TextureFormat.RGB24, false, false);
            RenderTexture previousActive = RenderTexture.active;
            try
            {
                foreach (SkinnedMeshRenderer source in root.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    if (!source.enabled || source.forceRenderingOff || source.sharedMesh == null) continue;
                    var mesh = new Mesh(); meshes.Add(mesh); source.BakeMesh(mesh);
                    var snapshot = new GameObject(source.name + "_EyeCpuSnapshot") { hideFlags = HideFlags.HideAndDontSave, layer = layer };
                    snapshots.Add(snapshot); snapshot.transform.SetParent(source.transform, false);
                    snapshot.AddComponent<MeshFilter>().sharedMesh = mesh;
                    MeshRenderer renderer = snapshot.AddComponent<MeshRenderer>(); renderer.sharedMaterials = source.sharedMaterials;
                    renderer.shadowCastingMode = source.shadowCastingMode; renderer.receiveShadows = source.receiveShadows;
                }
                Require(snapshots.Count > 0, "Visible avatar skins are required.");
                target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, 1024, 1024), 0, 0); pixels.Apply();
                float[] luminance = pixels.GetPixels32().Where((_, index) => index % 97 == 0)
                    .Select(pixel => (.2126f * pixel.r + .7152f * pixel.g + .0722f * pixel.b) / 255f).ToArray();
                Require(luminance.Max() - luminance.Min() > .05f, "Capture is blank.");
                File.WriteAllBytes(path, pixels.EncodeToPNG());
            }
            finally
            {
                camera.targetTexture = null; RenderTexture.active = previousActive;
                target.Release(); Object.DestroyImmediate(target); Object.DestroyImmediate(pixels);
                foreach (GameObject snapshot in snapshots) Object.DestroyImmediate(snapshot);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
            }
        }
        private static void Process(UnityAvatarCommandReceiver receiver, Vrm10Instance vrm) { Invoke(receiver, "LateUpdate"); vrm.Runtime.Process(); }
        private static void Send(UnityAvatarCommandReceiver receiver, string method, string json) => receiver.OnFlutterCommand(JsonUtility.ToJson(new Command { method = method, json = json }));
        private static void Set(object target, string name, object value) => target.GetType().GetField(name, Flags).SetValue(target, value);
        private static void Invoke(object target, string name, params object[] args) => target.GetType().GetMethod(name, Flags).Invoke(target, args);
        private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        private static string Hash(string path)
        {
            using var sha = SHA256.Create(); using var stream = File.OpenRead(path);
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
    }
}
#endif
