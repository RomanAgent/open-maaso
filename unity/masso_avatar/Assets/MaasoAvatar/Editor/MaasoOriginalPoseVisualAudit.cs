#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Render exact already-measured A/B snapshots from the independent
    /// normalized-rig audit. No second sampler, interpolation, runtime controller,
    /// phase matching heuristic or original asset mutation is introduced here.</summary>
    public static class MaasoOriginalPoseVisualAudit
    {
        private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private const BindingFlags StaticPrivate = BindingFlags.Static | BindingFlags.NonPublic;
        private static readonly string[] Clips = { "talk_calm_1", "g_beat_both", "g_offer_both", "g_chest_r" };
        private static readonly string[] Views = { "body", "both-arms", "left-arm", "right-arm" };

        public static void Run()
        {
            string input = Path.GetFullPath(Argument("-maasoOriginalPoseAuditInput", "/private/tmp/maaso-annie-roundtrip-20261016/receipt.json"));
            string output = Path.GetFullPath(Argument("-maasoOriginalPoseVisualOutput", "/private/tmp/maaso-original-pose-visual-20261016"));
            int rank = int.Parse(Argument("-maasoOriginalPoseWorstRank", "0"), System.Globalization.CultureInfo.InvariantCulture);
            Require(rank >= 0 && rank < 8, "Worst rank must be between zero and seven");
            JObject audit = JObject.Parse(File.ReadAllText(input));
            Require((int?)audit["auditVersion"] == 2, "Use the independent-fixture v2 audit with explicit authored-base alignment; old standalone upper-body snapshots are not comparable");
            Require((string)audit["model"] == Model && (string)audit["modelSha256"] == Sha(File.ReadAllBytes(Model)), "Snapshot model changed");
            Require((string)audit["sourcePackSha256"] == Sha(File.ReadAllBytes(MaasoOpenAnnieMotionImporter.SourceDirectory + "/pack.json")), "Pinned pack changed");
            Directory.CreateDirectory(output);
            var rows = new JArray();
            foreach (string name in Clips)
            {
                JObject clip = ((JArray)audit["clips"]).OfType<JObject>().Single(row => (string)row["name"] == name);
                Require((string)clip["sourceSha256"] == Sha(File.ReadAllBytes(MaasoOpenAnnieMotionImporter.SourceDirectory + "/" + name + ".json")), "Raw clip changed: " + name);
                Require((string)clip["clipSha256"] == Sha(File.ReadAllBytes(MaasoOpenAnnieMotionImporter.ClipDirectory + "/annie_" + name + ".anim")), "Saved clip changed: " + name);
                JArray worst = (JArray)clip["worstFrames"];
                Require(worst.Count > rank, "Measured worst frame unavailable: " + name);
                JObject selected = (JObject)worst[rank];
                Require(selected["authoredBaseAlignedSavedMappedRawBones"] is JObject, "Fair aligned native snapshot missing; never fall back to standalone saved clip");
                JObject alignment = (JObject)selected["bodyFrameAlignment"];
                Require(alignment != null && alignment["armMusclesOverridden"]?.Type == JTokenType.Boolean && (bool)alignment["armMusclesOverridden"] == false,
                    "Audit must prove native written arm channels were not replaced");
                JArray copied = (JArray)alignment["authoredBaseCopiedOnlyUnwrittenMuscles"];
                Require(copied != null && copied.All(channel => new[] { "Leg", "Foot", "Toe", "Eye", "Jaw" }.Any(allowed =>
                    ((string)channel).IndexOf(allowed, StringComparison.OrdinalIgnoreCase) >= 0)), "Only unwritten lower-body/eye/jaw baseline channels may be copied");
                rows.Add(RenderPair(name, selected, output));
            }
            File.WriteAllText(Path.Combine(output, "receipt.json"), new JObject {
                ["schema"] = "maaso-same-joy-original-pose-visual-v2", ["inputAudit"] = input,
                ["inputAuditSha256"] = Sha(File.ReadAllBytes(input)), ["model"] = Model, ["modelSha256"] = audit["modelSha256"],
                ["sourcePackSha256"] = audit["sourcePackSha256"], ["selectedInputRank"] = rank, ["pairs"] = rows,
                ["selectionBoundary"] = "Representative exact frame selected from the input unaligned local-arm-error ranking; this visual does not claim to be the maximum fair-aligned difference",
                ["A"] = "Pinned raw quaternion/hands/hips FK snapshot from exact-frame normalized-rig audit",
                ["B"] = "Saved native Humanoid arm channels at the identical exact time/full weight 1, with only source body frame and unwritten lower/eye/jaw baseline aligned; no arm curve override, controller mask or runtime overlays",
                ["commonModelPolicy"] = "Same Joy, same normalized control-rig definition, same Rigify skin-roll adapter and Joy elbow GPU correctives ON for BOTH columns; these model deformations preserve mapped joint positions",
                ["poseBoundary"] = "All mapped raw world matrices are restored and checked against the actual source/clip audit BEFORE identical model adapters. No pose resampling or manual anatomical repair.",
                ["renderBoundary"] = "Same union-of-both-poses camera bounds, fixed lighting/materials and CPU BakeMesh current-pose capture. Labels live in this receipt; paired PNG panels are unpainted A-left/B-right.",
                ["limits"] = "Same-Joy core-import pose evidence, not original Annie-B model/proportions, normal Maaso acoustic retiming or physical-device rendering/performance. No normal-runtime C column is fabricated.",
                ["visualHelperSha256"] = Sha(File.ReadAllBytes("Assets/MaasoAvatar/Editor/MaasoOriginalPoseVisualAudit.cs")),
                ["rigifyHelperSha256"] = Sha(File.ReadAllBytes("Assets/MaasoAvatar/Scripts/AvatarRigifyArmDeformation.cs")),
                ["correctiveHelperSha256"] = Sha(File.ReadAllBytes("Assets/MaasoAvatar/Scripts/AvatarJoyElbowCorrectives.cs")),
                ["correctiveProfileSha256"] = Sha(File.ReadAllBytes("Assets/Resources/MaasoAvatar/joy_elbow_correctives.json")),
            }.ToString());
            Debug.Log("[MaasoOriginalPoseVisualAudit] Wrote " + output);
        }

        private static JObject RenderPair(string name, JObject measured, string output)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
            root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity); root.transform.localScale = Vector3.one;
            var vrm = root.GetComponent<Vrm10Instance>(); vrm.enabled = false;
            var animator = root.GetComponent<Animator>(); animator.runtimeAnimatorController = null; animator.applyRootMotion = false;
            var rig = new Vrm10RuntimeControlRig(vrm.Humanoid, root.transform);
            UnityEngine.Avatar generated = rig.ControlRigAnimator.avatar;
            animator.enabled = false;
            var deformation = root.AddComponent<AvatarRigifyArmDeformation>();
            var correctives = root.AddComponent<AvatarJoyElbowCorrectives>();
            try
            {
                Require(deformation.Bind(root.transform), "Same-Joy Rigify model adapter must bind");
                Require(correctives.Bind(root.transform), "Same-Joy elbow model adapter must bind: " + correctives.LastFailure);
                var source = (JObject)measured["sourceMappedRawBones"];
                var saved = (JObject)measured["authoredBaseAlignedSavedMappedRawBones"];
                Require(source != null && saved != null, "Audit must contain complete source and saved mapped raw snapshots");
                var cameras = Views.ToDictionary(view => view, view => CameraRecipe(view, source, saved));
                Camera camera = (Camera)typeof(MaasoSpeechPerformanceReplay).GetMethod("CreateCamera", StaticPrivate).Invoke(null, new object[] { root });
                var columns = new JArray(); var files = new Dictionary<string, string[]>();
                foreach (string view in Views) files[view] = new string[2];
                int column = 0;
                foreach (var pose in new[] { (label: "A-raw-source", bones: source), (label: "B-native-aligned-fullweight", bones: saved) })
                {
                    deformation.RestoreBeforeAnimation();
                    JObject restored = RestoreAndValidate(vrm, pose.bones);
                    var jointPositions = pose.bones.Properties().ToDictionary(property => property.Name,
                        property => vrm.Humanoid.GetBoneTransform((HumanBodyBones)Enum.Parse(typeof(HumanBodyBones), property.Name)).position);
                    deformation.ApplyAfterVrm(); correctives.ApplyAfterVrm();
                    float jointShift = 0f;
                    foreach (var joint in jointPositions)
                        jointShift = Mathf.Max(jointShift, Vector3.Distance(joint.Value,
                            vrm.Humanoid.GetBoneTransform((HumanBodyBones)Enum.Parse(typeof(HumanBodyBones), joint.Key)).position));
                    Require(jointShift < .00002f, "Common model adaptation moved a mapped joint");
                    var captures = new JArray();
                    foreach (string view in Views)
                    {
                        JObject recipe = cameras[view];
                        camera.fieldOfView = (float)recipe["verticalFovDegrees"];
                        camera.transform.position = Vector(recipe["position"]); camera.transform.LookAt(Vector(recipe["target"]));
                        string path = Path.Combine(output, name + "-" + pose.label + "-" + view + ".png");
                        typeof(MaasoSpeechPerformanceReplay).GetMethod("Render", StaticPrivate).Invoke(null, new object[] { camera, root, path });
                        captures.Add(new JObject { ["view"] = view, ["path"] = path, ["sha256"] = Sha(File.ReadAllBytes(path)) });
                        files[view][column] = path;
                    }
                    columns.Add(new JObject { ["label"] = pose.label, ["snapshotRestore"] = restored, ["rigifyBound"] = deformation.Bound,
                        ["elbowCorrectivesBound"] = correctives.Bound, ["maximumModelAdapterJointShiftMeters"] = jointShift, ["captures"] = captures });
                    column++;
                }
                var paired = new JArray();
                foreach (var pair in files)
                {
                    string path = Path.Combine(output, name + "-AB-" + pair.Key + ".png"); JoinPanels(pair.Value[0], pair.Value[1], path);
                    paired.Add(new JObject { ["view"] = pair.Key, ["path"] = path, ["sha256"] = Sha(File.ReadAllBytes(path)), ["left"] = "A-raw-source", ["right"] = "B-native-aligned-fullweight" });
                }
                return new JObject { ["clip"] = name, ["timeSeconds"] = measured["timeSeconds"], ["sourceFrameTime"] = measured["sourceFrameTime"],
                    ["authoredFrame"] = measured["authoredFrame"], ["inputUnalignedRankingArmMaxDegrees"] = measured["savedArmMaxDegrees"], ["nativeBaselineAlignment"] = measured["bodyFrameAlignment"].DeepClone(),
                    ["sameExactTime"] = true, ["normalizedControlRigDefinition"] = generated != null && generated.isHuman,
                    ["runtimeControllersOrOverlays"] = false, ["columns"] = columns, ["cameraRecipes"] = JObject.FromObject(cameras), ["pairedCaptures"] = paired };
            }
            finally
            {
                correctives.Reset(); deformation.Reset();
                Object.DestroyImmediate(root); if (generated != null) Object.DestroyImmediate(generated);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            }
        }

        private static JObject RestoreAndValidate(Vrm10Instance vrm, JObject snapshot)
        {
            var rows = new List<(Transform bone, Matrix4x4 expected, string id)>();
            foreach (JProperty property in snapshot.Properties())
            {
                Require(Enum.TryParse(property.Name, out HumanBodyBones id), "Unknown measured humanoid bone");
                Transform bone = vrm.Humanoid.GetBoneTransform(id);
                Require(bone != null && bone.name == (string)property.Value["rawName"], "Same-model bone mapping changed: " + property.Name);
                rows.Add((bone, Matrix(property.Value["worldMatrix"]), property.Name));
            }
            Require(rows.Count >= 45 && rows.Select(row => row.bone).Distinct().Count() == rows.Count, "Incomplete/ambiguous normalized-rig raw snapshot");
            foreach (var row in rows.OrderBy(row => Depth(row.bone)))
                row.bone.SetPositionAndRotation(row.expected.GetColumn(3), Quaternion.LookRotation(row.expected.GetColumn(2), row.expected.GetColumn(1)));
            float position = 0f, rotation = 0f;
            foreach (var row in rows)
            {
                position = Mathf.Max(position, Vector3.Distance(row.bone.position, row.expected.GetColumn(3)));
                rotation = Mathf.Max(rotation, Quaternion.Angle(row.bone.rotation, Quaternion.LookRotation(row.expected.GetColumn(2), row.expected.GetColumn(1))));
            }
            Require(position < .00002f && rotation < .15f, "Recorded raw-pose replay changed measured joint positions/rotations");
            return new JObject { ["mappedBones"] = rows.Count, ["maximumPositionErrorMeters"] = position, ["maximumRotationErrorDegrees"] = rotation };
        }
        private static JObject CameraRecipe(string view, JObject a, JObject b)
        {
            bool Include(string id) => view == "body" ||
                ((view == "both-arms" || view.StartsWith("left", StringComparison.Ordinal) && id.StartsWith("Left", StringComparison.Ordinal) ||
                  view.StartsWith("right", StringComparison.Ordinal) && id.StartsWith("Right", StringComparison.Ordinal)) &&
                 (id.Contains("Shoulder") || id.Contains("Arm") || id.Contains("Hand") || id.Contains("Thumb") ||
                  id.Contains("Index") || id.Contains("Middle") || id.Contains("Ring") || id.Contains("Little")));
            Vector3[] points = new[] { a, b }.SelectMany(snapshot => snapshot.Properties()).Where(property => Include(property.Name))
                .Select(property => (Vector3)Matrix(property.Value["worldMatrix"]).GetColumn(3)).ToArray();
            Require(points.Length > 3, "Whole-arm camera bounds unavailable");
            Bounds bounds = new(points[0], Vector3.zero); foreach (Vector3 point in points) bounds.Encapsulate(point);
            bounds.Expand(view == "body" ? .28f : .14f);
            const float fov = 35f, aspect = 512f / 768f;
            float distance = Mathf.Max(bounds.size.y, bounds.size.x / aspect) / (2f * Mathf.Tan(fov * .5f * Mathf.Deg2Rad)) * 1.12f;
            Vector3 direction = view == "left-arm" || view == "right-arm" ? new Vector3(Mathf.Sign(bounds.center.x) * .28f, .05f, 1f).normalized : Vector3.forward;
            Vector3 position = bounds.center + direction * Mathf.Max(.5f, distance);
            return new JObject { ["position"] = Array(position), ["target"] = Array(bounds.center), ["verticalFovDegrees"] = fov,
                ["width"] = 512, ["height"] = 768, ["boundsFromBothPoses"] = true };
        }
        private static void JoinPanels(string a, string b, string output)
        {
            var left = new Texture2D(2, 2, TextureFormat.RGB24, false); var right = new Texture2D(2, 2, TextureFormat.RGB24, false); Texture2D result = null;
            try
            {
                Require(left.LoadImage(File.ReadAllBytes(a)) && right.LoadImage(File.ReadAllBytes(b)), "Captured panels cannot decode");
                Require(left.width == right.width && left.height == right.height, "Comparison panels differ in size");
                result = new Texture2D(left.width * 2, left.height, TextureFormat.RGB24, false);
                result.SetPixels(0, 0, left.width, left.height, left.GetPixels()); result.SetPixels(left.width, 0, right.width, right.height, right.GetPixels());
                result.Apply(); File.WriteAllBytes(output, result.EncodeToPNG());
            }
            finally { Object.DestroyImmediate(left); Object.DestroyImmediate(right); if (result != null) Object.DestroyImmediate(result); }
        }
        private static Matrix4x4 Matrix(JToken value)
        { Require(value is JArray rows && rows.Count == 4, "Matrix snapshot invalid"); var result = new Matrix4x4(); for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) result[r, c] = (float)value[r][c]; return result; }
        private static int Depth(Transform value) { int depth = 0; while (value.parent != null) { depth++; value = value.parent; } return depth; }
        private static Vector3 Vector(JToken value) => new((float)value[0], (float)value[1], (float)value[2]);
        private static JArray Array(Vector3 value) => new(value.x, value.y, value.z);
        private static void Require(bool value, string message) { if (!value) throw new InvalidDataException(message); }
        private static string Sha(byte[] bytes) { using var hash = SHA256.Create(); return string.Concat(hash.ComputeHash(bytes).Select(b => b.ToString("x2"))); }
        private static string Argument(string key, string fallback) { string[] args = Environment.GetCommandLineArgs(); int i = System.Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback; }
    }
}
#endif
