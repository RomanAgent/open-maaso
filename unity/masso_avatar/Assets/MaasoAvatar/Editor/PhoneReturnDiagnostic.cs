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
    /// <summary>Complete phone-overlay timeline against the installed Joy.
    /// Captures CPU skinned geometry, not stale synchronous Editor GPU skins.
    /// Original materials are retained. Fixed frontal diagnostic fill is clearly
    /// recorded and applies equally to all sample images, not the saved scene.</summary>
    public static class PhoneReturnDiagnostic
    {
        private const string ScenePath = "Assets/MaasoAvatar/Scenes/Companion.unity";
        private const string ModelPath = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const BindingFlags Flags = BindingFlags.Instance | BindingFlags.NonPublic;
        [Serializable] private sealed class Command { public string method, json; }
        [Serializable] private sealed class Arm
        {
            public Vector3 shoulder, elbow, wrist, knuckle;
            public Quaternion upperLocal, lowerLocal, handLocal;
            public float elbowAngle, wristAngle, upperStepDegrees, lowerStepDegrees, handStepDegrees;
        }
        [Serializable] private sealed class Frame
        {
            public string sequence, phase;
            public float now, elapsed;
            public bool visible, ownsHands;
            public Vector3 phonePosition;
            public Quaternion phoneRotation;
            public float phoneStepDegrees;
            public Arm left, right;
        }
        [Serializable] private sealed class Report
        {
            public string modelSha256, sceneSha256Before, sceneSha256After;
            public string graphicsDevice, avatarScene;
            public string method = "Saved Companion Joy + real AvatarPhoneInteractionController at 60Hz -> VRM.Runtime.Process -> CPU BakeMesh. Fixed same camera/materials, diagnostic-only frontal white fill1.25, not a player screenshot.";
            public float palmLength, palmWidth, phoneWidth, phoneHeight, maxWristDegrees, maxArmFrameDegrees;
            public List<Frame> frames = new();
            public List<string> captures = new();
            public string failure;
        }
        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_PHONE_RETURN_AUDIT") ?? "/tmp/maaso-phone-return";
            Directory.CreateDirectory(output);
            var report = new Report { modelSha256 = Hash(ModelPath), sceneSha256Before = Hash(ScenePath),
                graphicsDevice = SystemInfo.graphicsDeviceType.ToString() };
            GameObject cameraObject = null, fillObject = null;
            AvatarPhoneInteractionController controller = null;
            try
            {
                if (SystemInfo.graphicsDeviceType == UnityEngine.Rendering.GraphicsDeviceType.Null)
                    throw new InvalidOperationException("Phone image audit requires a graphics device; do not use -nographics.");
                var scene = EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
                var receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                Invoke(receiver, "Awake");
                receiver.OnFlutterCommand(JsonUtility.ToJson(new Command { method = "setLocalAvatarVisible", json = "{\"visible\":true}" }));
                Transform root = receiver.ActiveAvatarRoot;
                report.avatarScene = root.gameObject.scene.name;
                var vrm = root.GetComponentInChildren<Vrm10Instance>(true);
                var animator = root.GetComponentInChildren<Animator>(true);
                animator.Rebind(); animator.Play("idle_shrug", 0, 0f); animator.Update(0f);
                typeof(UnityAvatarCommandReceiver).GetField("autoBlink", Flags).SetValue(receiver, false);
                typeof(UnityAvatarCommandReceiver).GetField("actionPoseHoldUntil", Flags).SetValue(receiver, Time.realtimeSinceStartup + 3600f);
                Invoke(receiver, "LateUpdate"); vrm.Runtime.Process();
                Transform hand = animator.GetBoneTransform(HumanBodyBones.LeftHand);
                report.palmLength = Vector3.Distance(hand.position, animator.GetBoneTransform(HumanBodyBones.LeftMiddleProximal).position);
                report.palmWidth = Vector3.Distance(animator.GetBoneTransform(HumanBodyBones.LeftIndexProximal).position,
                    animator.GetBoneTransform(HumanBodyBones.LeftLittleProximal).position);
                var used = new HashSet<int>(Object.FindObjectsByType<Renderer>(FindObjectsInactive.Include).Select(renderer => renderer.gameObject.layer));
                int layer = Enumerable.Range(8, 23).Reverse().First(value => !used.Contains(value));
                cameraObject = new GameObject("PhoneReturnDiagnosticCamera") { hideFlags = HideFlags.HideAndDontSave };
                Camera camera = cameraObject.AddComponent<Camera>(); camera.enabled = false;
                // Isolate by layer, not the originally opened Scene handle: the
                // receiver may parent the rendered avatar into its persistent Home scene.
                camera.useOcclusionCulling = false;
                camera.orthographic = true; camera.orthographicSize = .58f; camera.aspect = 1f;
                camera.nearClipPlane = .01f; camera.farClipPlane = 10f; camera.cullingMask = 1 << layer;
                camera.clearFlags = CameraClearFlags.SolidColor; camera.backgroundColor = new Color(.93f, .93f, .93f);
                Vector3 focus = animator.GetBoneTransform(HumanBodyBones.Hips).position + root.up * .28f;
                camera.transform.SetPositionAndRotation(focus + root.forward * 2f + root.right * .35f,
                    Quaternion.LookRotation(-root.forward * 2f - root.right * .35f, root.up));
                fillObject = new GameObject("PhoneReturn_DIAGNOSTIC_ONLY_FrontalFill") { hideFlags = HideFlags.HideAndDontSave };
                Light fill = fillObject.AddComponent<Light>(); fill.type = LightType.Directional; fill.intensity = 1.25f;
                fill.color = Color.white; fill.shadows = LightShadows.None; fill.cullingMask = 1 << layer; fill.transform.rotation = camera.transform.rotation;
                int serial = 0;
                foreach (string sequence in new[] { "reading-return", "replying-return", "early-return" })
                {
                    controller = new AvatarPhoneInteractionController(result => { if (!result.ok) Debug.LogWarning("Phone diagnostic result: " + result.code); });
                    var steps = sequence == "early-return"
                        ? new[] { ("reading", 0f, 18), ("none", .3f, 66) }
                        : sequence == "replying-return"
                            ? new[] { ("reading", 0f, 72), ("replying", 1.2f, 42), ("none", 1.9f, 66) }
                            : new[] { ("reading", 0f, 72), ("none", 1.2f, 66) };
                    Frame previous = null;
                    foreach (var (phase, start, count) in steps)
                    {
                        controller.Execute(new AvatarPhoneCommand { requestId = "return-audit-" + ++serial, interactionId = sequence,
                            phase = phase, sequence = serial, expiresAtMs = 1000 + (long)(start * 1000f) + 5000 }, root, start, 1000 + (long)(start * 1000f));
                        if (report.phoneWidth == 0f)
                        {
                            Transform chassis = controller.Phone.transform.Find("Rounded metal chassis");
                            Vector3 size = chassis.GetComponent<MeshFilter>().sharedMesh.bounds.size;
                            report.phoneWidth = chassis.TransformVector(Vector3.right * size.x).magnitude;
                            report.phoneHeight = chassis.TransformVector(Vector3.up * size.y).magnitude;
                        }
                        for (int index = 0; index <= count; index++)
                        {
                            float elapsed = index / 60f, now = start + elapsed;
                            controller.Advance(now, 1000 + (long)(now * 1000)); vrm.Runtime.Process();
                            var sample = new Frame { sequence = sequence, phase = phase, now = now, elapsed = elapsed,
                                visible = controller.Phone != null && controller.Phone.activeSelf, ownsHands = controller.OwnsHands,
                                phonePosition = controller.Phone != null ? controller.Phone.transform.position : Vector3.zero,
                                phoneRotation = controller.Phone != null ? controller.Phone.transform.rotation : Quaternion.identity,
                                left = Measure(animator, true, previous?.left), right = Measure(animator, false, previous?.right) };
                            sample.phoneStepDegrees = previous != null ? Quaternion.Angle(previous.phoneRotation, sample.phoneRotation) : 0f;
                            report.maxWristDegrees = Mathf.Max(report.maxWristDegrees, sample.left.wristAngle, sample.right.wristAngle);
                            report.maxArmFrameDegrees = Mathf.Max(report.maxArmFrameDegrees,
                                sample.left.upperStepDegrees, sample.left.lowerStepDegrees, sample.left.handStepDegrees,
                                sample.right.upperStepDegrees, sample.right.lowerStepDegrees, sample.right.handStepDegrees);
                            report.frames.Add(sample); previous = sample;
                            if ((phase == "none" && index % 9 == 0) || (phase != "none" && index == count))
                            {
                                string path = Path.Combine(output, sequence + "_" + phase + "_" + index.ToString("D3") + ".png");
                                Capture(camera, root, layer, path); report.captures.Add(path);
                            }
                        }
                    }
                    controller.Reset("diagnostic_complete"); controller = null; vrm.Runtime.Process();
                }
            }
            catch (Exception error) { report.failure = error.ToString(); throw; }
            finally
            {
                controller?.Reset("diagnostic_complete");
                if (cameraObject != null) Object.DestroyImmediate(cameraObject);
                if (fillObject != null) Object.DestroyImmediate(fillObject);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                report.sceneSha256After = Hash(ScenePath);
                File.WriteAllText(Path.Combine(output, "phone-return.json"), JsonUtility.ToJson(report, true));
                Debug.Log("[PhoneReturnDiagnostic] output=" + output + " maxWrist=" + report.maxWristDegrees + " maxArmFrame=" + report.maxArmFrameDegrees);
            }
        }
        private static Arm Measure(Animator animator, bool left, Arm before)
        {
            Transform upper = animator.GetBoneTransform(left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm);
            Transform lower = animator.GetBoneTransform(left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm);
            Transform hand = animator.GetBoneTransform(left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand);
            Transform knuckle = animator.GetBoneTransform(left ? HumanBodyBones.LeftMiddleProximal : HumanBodyBones.RightMiddleProximal);
            return new Arm { shoulder = upper.position, elbow = lower.position, wrist = hand.position, knuckle = knuckle.position,
                upperLocal = upper.localRotation, lowerLocal = lower.localRotation, handLocal = hand.localRotation,
                elbowAngle = Vector3.Angle(upper.position - lower.position, hand.position - lower.position),
                wristAngle = Vector3.Angle(hand.position - lower.position, knuckle.position - hand.position),
                upperStepDegrees = before != null ? Quaternion.Angle(before.upperLocal, upper.localRotation) : 0f,
                lowerStepDegrees = before != null ? Quaternion.Angle(before.lowerLocal, lower.localRotation) : 0f,
                handStepDegrees = before != null ? Quaternion.Angle(before.handLocal, hand.localRotation) : 0f };
        }
        private static void Capture(Camera camera, Transform root, int layer, string path)
        {
            var snapshots = new List<GameObject>(); var meshes = new List<Mesh>();
            var layers = new Dictionary<GameObject, int>();
            var target = new RenderTexture(768, 768, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB) { antiAliasing = 4 };
            var pixels = new Texture2D(768, 768, TextureFormat.RGB24, false, false); RenderTexture previous = RenderTexture.active;
            try
            {
                foreach (SkinnedMeshRenderer source in root.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    if (!source.enabled || source.forceRenderingOff) continue;
                    var mesh = new Mesh(); source.BakeMesh(mesh); meshes.Add(mesh);
                    var copy = new GameObject(source.name + "_PhoneCpuSnapshot") { hideFlags = HideFlags.HideAndDontSave, layer = layer };
                    snapshots.Add(copy); copy.transform.SetParent(source.transform, false);
                    copy.AddComponent<MeshFilter>().sharedMesh = mesh; copy.AddComponent<MeshRenderer>().sharedMaterials = source.sharedMaterials;
                }
                if (snapshots.Count == 0)
                    throw new InvalidOperationException("No visible skins in phone capture: " + string.Join(", ",
                        root.GetComponentsInChildren<SkinnedMeshRenderer>(true).Select(renderer => renderer.name +
                            " active=" + renderer.gameObject.activeInHierarchy + " enabled=" + renderer.enabled + " forcedOff=" + renderer.forceRenderingOff)));
                foreach (MeshRenderer part in root.GetComponentsInChildren<MeshRenderer>())
                {
                    if (snapshots.Contains(part.gameObject)) continue;
                    layers[part.gameObject] = part.gameObject.layer; part.gameObject.layer = layer;
                }
                target.Create(); camera.targetTexture = target; camera.Render(); RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, 768, 768), 0, 0); pixels.Apply();
                Color32[] colors = pixels.GetPixels32(); float low = 1f, high = 0f;
                for (int pixel = 0; pixel < colors.Length; pixel += 97)
                {
                    Color32 c = colors[pixel]; float value = (.2126f * c.r + .7152f * c.g + .0722f * c.b) / 255f;
                    low = Mathf.Min(low, value); high = Mathf.Max(high, value);
                }
                File.WriteAllBytes(path, pixels.EncodeToPNG());
                if (high - low < .05f) throw new InvalidOperationException("Blank phone capture " + path +
                    "; snapshotCount=" + snapshots.Count + "; camera=" + camera.transform.position + "; root=" + root.position);
            }
            finally
            {
                foreach (var pair in layers) pair.Key.layer = pair.Value;
                foreach (GameObject copy in snapshots) Object.DestroyImmediate(copy);
                foreach (Mesh mesh in meshes) Object.DestroyImmediate(mesh);
                camera.targetTexture = null; RenderTexture.active = previous; target.Release(); Object.DestroyImmediate(target); Object.DestroyImmediate(pixels);
            }
        }
        private static void Invoke(object target, string name) => target.GetType().GetMethod(name, Flags).Invoke(target, null);
        private static string Hash(string path) { using var sha = SHA256.Create(); return BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(path))).Replace("-", "").ToLowerInvariant(); }
    }
}
#endif
