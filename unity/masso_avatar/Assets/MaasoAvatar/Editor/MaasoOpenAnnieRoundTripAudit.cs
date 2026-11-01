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
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Read-only diagnostic. Compares pinned normalized FK, its HumanPose
    /// projection, and the saved muscle clip using the SAME Joy reference-rig
    /// definition in isolated instances at the
    /// identical frame/half-frame time. No controller, overlays, VRM runtime,
    /// skin adapter, IK, camera, renderer or source asset is changed/saved.
    /// </summary>
    public static class MaasoOpenAnnieRoundTripAudit
    {
        private const string Model = "Assets/MaasoAvatar/Models/Default/Joy.vrm";
        private static readonly MethodInfo Transfer = typeof(Vrm10RuntimeControlRig).GetMethod("Process", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly MethodInfo MuscleCurveName = typeof(MaasoOpenAnnieMotionImporter).GetMethod("CurveMuscleName", BindingFlags.Static | BindingFlags.NonPublic);

        public static void Run()
        {
            string output = Environment.GetEnvironmentVariable("MAASO_ANNIE_ROUNDTRIP_AUDIT_OUTPUT") ??
                Path.Combine(Path.GetTempPath(), "maaso-annie-roundtrip-20261016");
            Directory.CreateDirectory(output);
            JObject pack = JObject.Parse(File.ReadAllText(MaasoOpenAnnieMotionImporter.SourceDirectory + "/pack.json"));
            var clips = new JArray();
            foreach (string name in new[] { "talk_calm_1", "g_beat_both", "g_offer_both", "g_chest_r" })
                clips.Add(AuditClip(name, pack));
            var receipt = new JObject
            {
                ["scope"] = "Same-Joy normalized FK versus HumanPose projection and saved Humanoid clip; exact frames and half-frames, no overlays. Not original-Annie-model visual equivalence.",
                ["auditVersion"] = 2,
                ["model"] = Model,
                ["modelSha256"] = Sha(File.ReadAllBytes(Model)),
                ["sourcePackSha256"] = Sha(File.ReadAllBytes(MaasoOpenAnnieMotionImporter.SourceDirectory + "/pack.json")),
                ["clips"] = clips,
            };
            File.WriteAllText(Path.Combine(output, "receipt.json"), receipt.ToString());
            Debug.Log("[OpenAnnieRoundTrip] " + output);
            foreach (JObject clip in clips)
                Debug.Log("[OpenAnnieRoundTrip] " + clip["name"] + " source→HumanPose armMaxDeg=" +
                    clip["sourceToHumanPose"]["armLocalDegrees"]["max"] + "; source→saved armMaxDeg=" +
                    clip["sourceToSavedClip"]["armLocalDegrees"]["max"] + "; curveParity=" + clip["exactFrameMuscleCurveError"]["max"]);
        }

        private static JObject AuditClip(string name, JObject pack)
        {
            string sourcePath = MaasoOpenAnnieMotionImporter.SourceDirectory + "/" + name + ".json";
            byte[] bytes = File.ReadAllBytes(sourcePath);
            JObject metadata = (JObject)pack["clips"][name];
            if (Sha(bytes) != (string)metadata["sha256"]) throw new InvalidDataException("Source SHA mismatch " + name);
            JObject data = JObject.Parse(System.Text.Encoding.UTF8.GetString(bytes));
            AnimationClip clip = AssetDatabase.LoadAssetAtPath<AnimationClip>(MaasoOpenAnnieMotionImporter.ClipDirectory + "/annie_" + name + ".anim");
            if (clip == null || !clip.humanMotion) throw new InvalidDataException("Saved Humanoid clip missing " + name);
            using var f = new Fixture(null);
            using var projectionFixture = new Fixture(null);
            using var nativeFixture = new Fixture(clip);
            using var alignedFixture = new Fixture(null);
            var projected = new Comparison();
            var saved = new Comparison();
            var projectionToSaved = new Comparison();
            var aligned = new Comparison();
            var baseAligned = new Comparison();
            var projectedToBaseAligned = new Comparison();
            var exactCurves = new Stats();
            var halfCurves = new Stats();
            var readback = new Stats();
            var getterMutation = new Stats();
            var outside = new Dictionary<string, (double Min, double Max)>();
            var alignmentMuscleReadback = new Stats();
            var worstRows = new List<JObject>();
            var frameRows = new JArray();
            var curves = AnimationUtility.GetCurveBindings(clip).Where(binding => binding.type == typeof(Animator))
                .ToDictionary(binding => binding.propertyName, binding => AnimationUtility.GetEditorCurve(clip, binding));
            int frames = (int)data["frames"];
            bool loop = (bool)data["loop"];
            int halfSamples = loop ? frames * 2 : frames * 2 - 1;
            for (int sample = 0; sample < halfSamples; sample++)
            {
                double frameTime = sample * .5;
                double time = frameTime / (double)(float)data["fps"];
                f.ApplySource(data, (JObject)pack["hands"], frameTime);
                Snapshot source = f.Capture();
                HumanPose pose = new HumanPose();
                f.Handler.GetHumanPose(ref pose);
                Snapshot afterGetter = f.Capture();
                getterMutation.Add(source.MaximumLocalDifference(afterGetter));
                float[] sourceMuscles = (float[])pose.muscles.Clone();
                for (int muscle = 0; muscle < sourceMuscles.Length; muscle++)
                {
                    double value = sourceMuscles[muscle];
                    string muscleName = HumanTrait.MuscleName[muscle];
                    if (Math.Abs(value) > 1.000001)
                    {
                        if (!outside.TryGetValue(muscleName, out var range)) range = (value, value);
                        outside[muscleName] = (Math.Min(range.Min, value), Math.Max(range.Max, value));
                    }
                    string property = (string)MuscleCurveName.Invoke(null, new object[] { muscleName });
                    if (!curves.TryGetValue(property, out AnimationCurve curve)) continue;
                    double error = Math.Abs(curve.Evaluate((float)time) - value);
                    if (sample % 2 == 0) exactCurves.Add(error); else halfCurves.Add(error);
                }
                projectionFixture.Reset();
                projectionFixture.Handler.SetHumanPose(ref pose);
                Snapshot human = projectionFixture.Capture();
                double projectionWorst = projected.Add(source, human);
                nativeFixture.Reset();
                nativeFixture.Playable.SetTime(time);
                nativeFixture.Graph.Evaluate(0f);
                Snapshot actual = nativeFixture.Capture();
                double savedWorst = saved.Add(source, actual);
                projectionToSaved.Add(human, actual);
                HumanPose native = new HumanPose();
                nativeFixture.Handler.GetHumanPose(ref native);
                for (int muscle = 0; muscle < sourceMuscles.Length; muscle++)
                {
                    string property = (string)MuscleCurveName.Invoke(null, new object[] { HumanTrait.MuscleName[muscle] });
                    if (curves.TryGetValue(property, out AnimationCurve curve))
                        readback.Add(Math.Abs(native.muscles[muscle] - curve.Evaluate((float)time)));
                }
                // Standalone upper clips intentionally have no RootT/Q or leg
                // curves. First compare only a common BODY frame, then a fair
                // inherited base for unwritten channels. Written arm muscles
                // always remain the saved clip's decoded values.
                var bodyPose = new HumanPose { bodyPosition = pose.bodyPosition, bodyRotation = pose.bodyRotation,
                    muscles = (float[])native.muscles.Clone() };
                alignedFixture.Reset();
                alignedFixture.Handler.SetHumanPose(ref bodyPose);
                Snapshot bodyAligned = alignedFixture.Capture();
                aligned.Add(source, bodyAligned);
                var basePose = new HumanPose { bodyPosition = pose.bodyPosition, bodyRotation = pose.bodyRotation,
                    muscles = (float[])native.muscles.Clone() };
                for (int muscle = 0; muscle < basePose.muscles.Length; muscle++)
                {
                    string property = (string)MuscleCurveName.Invoke(null, new object[] { HumanTrait.MuscleName[muscle] });
                    if (!curves.ContainsKey(property)) basePose.muscles[muscle] = sourceMuscles[muscle];
                }
                alignedFixture.Reset();
                alignedFixture.Handler.SetHumanPose(ref basePose);
                Snapshot authoredBaseAligned = alignedFixture.Capture();
                baseAligned.Add(source, authoredBaseAligned);
                projectedToBaseAligned.Add(human, authoredBaseAligned);
                HumanPose alignedReadback = new HumanPose();
                alignedFixture.Handler.GetHumanPose(ref alignedReadback);
                for (int muscle = 0; muscle < sourceMuscles.Length; muscle++)
                {
                    string property = (string)MuscleCurveName.Invoke(null, new object[] { HumanTrait.MuscleName[muscle] });
                    if (curves.ContainsKey(property)) alignmentMuscleReadback.Add(Math.Abs(alignedReadback.muscles[muscle] - native.muscles[muscle]));
                }
                var summary = new JObject
                {
                    ["timeSeconds"] = time, ["sourceFrameTime"] = frameTime, ["authoredFrame"] = sample % 2 == 0,
                    ["projectionArmMaxDegrees"] = projectionWorst, ["savedArmMaxDegrees"] = savedWorst,
                };
                frameRows.Add(summary);
                if (worstRows.Count < 8 || savedWorst > worstRows.Min(row => (double)row["savedArmMaxDegrees"]))
                {
                    var detail = (JObject)summary.DeepClone();
                    detail["bones"] = source.Differences(actual);
                    detail["sourceMappedRawBones"] = source.MappedRaw();
                    detail["savedMappedRawBones"] = actual.MappedRaw();
                    detail["bodyAlignedSavedMappedRawBones"] = bodyAligned.MappedRaw();
                    detail["authoredBaseAlignedSavedMappedRawBones"] = authoredBaseAligned.MappedRaw();
                    detail["bodyFrameAlignment"] = new JObject
                    {
                        ["sourcePosition"] = V(pose.bodyPosition), ["sourceRotation"] = Q(pose.bodyRotation),
                        ["standaloneNativePosition"] = V(native.bodyPosition), ["standaloneNativeRotation"] = Q(native.bodyRotation),
                        ["armMusclesOverridden"] = false,
                        ["authoredBaseCopiedOnlyUnwrittenMuscles"] = new JArray(Enumerable.Range(0, sourceMuscles.Length).Where(muscle =>
                            !curves.ContainsKey((string)MuscleCurveName.Invoke(null, new object[] { HumanTrait.MuscleName[muscle] }))).Select(muscle => HumanTrait.MuscleName[muscle])),
                    };
                    worstRows.Add(detail);
                    if (worstRows.Count > 8) worstRows.Remove(worstRows.OrderBy(row => (double)row["savedArmMaxDegrees"]).First());
                }
            }
            return new JObject
            {
                ["name"] = name, ["frames"] = frames, ["samples"] = halfSamples, ["loop"] = loop,
                ["sourceSha256"] = Sha(bytes), ["clipSha256"] = Sha(File.ReadAllBytes(AssetDatabase.GetAssetPath(clip))),
                ["sourceToHumanPose"] = projected.Json(), ["sourceToSavedClip"] = saved.Json(),
                ["humanPoseToSavedClip"] = projectionToSaved.Json(),
                ["sourceToSavedBodyFrameAligned"] = aligned.Json(),
                ["sourceToSavedAuthoredBaseAligned"] = baseAligned.Json(),
                ["humanPoseToSavedAuthoredBaseAligned"] = projectedToBaseAligned.Json(),
                ["alignedWrittenMuscleReadbackError"] = alignmentMuscleReadback.Json(),
                ["exactFrameMuscleCurveError"] = exactCurves.Json(), ["halfFrameMuscleCurveError"] = halfCurves.Json(),
                ["nativeMuscleReadbackVersusCurve"] = readback.Json(), ["getterMutationDegrees"] = getterMutation.Json(),
                ["sourceMusclesOutsideUnitRange"] = new JObject(outside.Select(pair => new JProperty(pair.Key, new JArray(pair.Value.Min, pair.Value.Max)))),
                ["worstFrames"] = new JArray(worstRows.OrderByDescending(row => (double)row["savedArmMaxDegrees"]).Take(8)),
                ["allFrameSummary"] = frameRows,
            };
        }

        private sealed class Fixture : IDisposable
        {
            public readonly GameObject Root;
            public readonly Vrm10RuntimeControlRig Rig;
            public readonly HumanPoseHandler Handler;
            public PlayableGraph Graph;
            public AnimationClipPlayable Playable;
            private readonly Animator animator;
            private readonly UnityEngine.Avatar generated;
            private readonly Vector3 hipsRest;
            public Fixture(AnimationClip clip)
            {
                Root = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>(Model));
                Root.name = "DisposableExactOpenAnnieRoundTrip";
                Root.hideFlags = HideFlags.HideAndDontSave;
                Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
                Root.transform.localScale = Vector3.one;
                var vrm = Root.GetComponent<Vrm10Instance>();
                vrm.enabled = false;
                animator = Root.GetComponent<Animator>();
                animator.runtimeAnimatorController = null;
                animator.applyRootMotion = false;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                Rig = new Vrm10RuntimeControlRig(vrm.Humanoid, Root.transform);
                generated = Rig.ControlRigAnimator.avatar;
                animator.Rebind();
                Handler = new HumanPoseHandler(generated, Root.transform);
                hipsRest = Rig.GetBoneTransform(HumanBodyBones.Hips).localPosition;
                if (clip == null) return;
                Graph = PlayableGraph.Create("Read-only exact Open Annie round trip");
                Graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
                Playable = AnimationClipPlayable.Create(Graph, clip);
                Playable.SetApplyFootIK(false);
                Playable.SetApplyPlayableIK(false);
                Playable.SetSpeed(0);
                AnimationPlayableOutput.Create(Graph, "Same normalized Joy reference", animator).SetSourcePlayable(Playable);
                Graph.Play();
            }
            public void Reset()
            {
                Root.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
                foreach (var bone in Rig.Bones.Values) bone.ControlBone.localRotation = Quaternion.identity;
                Rig.GetBoneTransform(HumanBodyBones.Hips).localPosition = hipsRest;
            }
            public void ApplySource(JObject data, JObject hands, double frameTime)
            {
                Reset();
                int frames = (int)data["frames"];
                double x = (bool)data["loop"] ? frameTime % frames : Math.Min(Math.Max(frameTime, 0), frames - 1);
                int a = (int)Math.Floor(x), b = (bool)data["loop"] ? (a + 1) % frames : Math.Min(a + 1, frames - 1);
                float mix = (float)(x - a);
                foreach (JProperty hand in hands.Properties())
                    if (MaasoOpenAnnieMotionImporter.TryMapBone(hand.Name, out HumanBodyBones id) && Rig.Bones.TryGetValue(id, out var bone))
                        bone.ControlBone.localRotation = MaasoOpenAnnieMotionImporter.SourceQuaternion(hand.Value.ToObject<float[]>(), 0);
                foreach (JProperty track in ((JObject)data["bones"]).Properties())
                {
                    if (!MaasoOpenAnnieMotionImporter.TryMapBone(track.Name, out HumanBodyBones id) || !Rig.Bones.TryGetValue(id, out var bone))
                        throw new InvalidDataException("Unknown source bone " + track.Name);
                    float[] values = track.Value.ToObject<float[]>();
                    bone.ControlBone.localRotation = Quaternion.Slerp(
                        MaasoOpenAnnieMotionImporter.SourceQuaternion(values, a * 4),
                        MaasoOpenAnnieMotionImporter.SourceQuaternion(values, b * 4), mix);
                }
                float[] hips = data["hips_position"]?.ToObject<float[]>();
                if (hips != null)
                {
                    Vector3 p = Vector3.Lerp(new Vector3(hips[a * 3], hips[a * 3 + 1], hips[a * 3 + 2]),
                        new Vector3(hips[b * 3], hips[b * 3 + 1], hips[b * 3 + 2]), mix);
                    Rig.GetBoneTransform(HumanBodyBones.Hips).localPosition = hipsRest + MaasoOpenAnnieMotionImporter.SourcePosition(p);
                }
            }
            public Snapshot Capture()
            {
                Transfer.Invoke(Rig, null);
                return new Snapshot(Rig);
            }
            public void Dispose()
            {
                if (Graph.IsValid()) Graph.Destroy();
                Handler.Dispose();
                Object.DestroyImmediate(Root);
                Object.DestroyImmediate(generated);
            }
        }

        private sealed class BonePose
        {
            public Quaternion Local, World, RawWorld;
            public Vector3 Position, RawPosition;
            public string RawName;
            public Matrix4x4 RawMatrix;
        }
        private sealed class Snapshot
        {
            public readonly Dictionary<HumanBodyBones, BonePose> Bones;
            public Snapshot(Vrm10RuntimeControlRig rig)
            {
                Bones = rig.Bones.ToDictionary(pair => pair.Key, pair => new BonePose
                {
                    Local = pair.Value.ControlBone.localRotation, World = pair.Value.ControlBone.rotation,
                    Position = pair.Value.ControlBone.position, RawWorld = pair.Value.ControlTarget.rotation,
                    RawPosition = pair.Value.ControlTarget.position,
                    RawName = pair.Value.ControlTarget.name, RawMatrix = pair.Value.ControlTarget.localToWorldMatrix,
                });
            }
            public JObject MappedRaw() => new JObject(Bones.Select(pair => new JProperty(pair.Key.ToString(), new JObject
            {
                ["rawName"] = pair.Value.RawName,
                ["worldMatrix"] = new JArray(Enumerable.Range(0, 4).Select(row =>
                    new JArray(Enumerable.Range(0, 4).Select(column => pair.Value.RawMatrix[row, column])))),
            })));
            public double MaximumLocalDifference(Snapshot other) => Bones.Max(pair => Angle(pair.Value.Local, other.Bones[pair.Key].Local));
            public JObject Differences(Snapshot other) => new JObject(Bones.Where(pair => IsArm(pair.Key)).Select(pair =>
                new JProperty(pair.Key.ToString(), new JObject
                {
                    ["localDegrees"] = Angle(pair.Value.Local, other.Bones[pair.Key].Local),
                    ["worldDegrees"] = Angle(pair.Value.World, other.Bones[pair.Key].World),
                    ["rawWorldDegrees"] = Angle(pair.Value.RawWorld, other.Bones[pair.Key].RawWorld),
                    ["sourceLocalQuaternion"] = Q(pair.Value.Local), ["savedLocalQuaternion"] = Q(other.Bones[pair.Key].Local),
                    ["sourceRawWorldQuaternion"] = Q(pair.Value.RawWorld), ["savedRawWorldQuaternion"] = Q(other.Bones[pair.Key].RawWorld),
                    ["sourcePosition"] = V(pair.Value.Position), ["savedPosition"] = V(other.Bones[pair.Key].Position),
                    ["sourceRawPosition"] = V(pair.Value.RawPosition), ["savedRawPosition"] = V(other.Bones[pair.Key].RawPosition),
                })));
        }
        private sealed class Comparison
        {
            private readonly Dictionary<string, Stats> metrics = new();
            private readonly Dictionary<string, Stats> bones = new();
            public double Add(Snapshot source, Snapshot actual)
            {
                double worst = 0;
                foreach (var pair in source.Bones)
                {
                    HumanBodyBones id = pair.Key;
                    if (!IsArm(id)) continue;
                    BonePose a = pair.Value, b = actual.Bones[id];
                    bool major = IsMajor(id);
                    double local = Angle(a.Local, b.Local);
                    AddMetric(major ? "armLocalDegrees" : "fingerLocalDegrees", local);
                    AddMetric(major ? "armWorldDegrees" : "fingerWorldDegrees", Angle(a.World, b.World));
                    AddMetric(major ? "rawArmWorldDegrees" : "rawFingerWorldDegrees", Angle(a.RawWorld, b.RawWorld));
                    if (major) worst = Math.Max(worst, local);
                    if (!bones.TryGetValue(id.ToString(), out Stats metric)) bones.Add(id.ToString(), metric = new Stats());
                    metric.Add(local);
                    bool left = id.ToString().StartsWith("Left", StringComparison.Ordinal);
                    HumanBodyBones shoulderId = left ? HumanBodyBones.LeftShoulder : HumanBodyBones.RightShoulder;
                    HumanBodyBones upperId = left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm;
                    HumanBodyBones lowerId = left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm;
                    HumanBodyBones handId = left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand;
                    double reach = Vector3.Distance(source.Bones[upperId].Position, source.Bones[lowerId].Position) +
                        Vector3.Distance(source.Bones[lowerId].Position, source.Bones[handId].Position);
                    Vector3 sa = a.Position - source.Bones[shoulderId].Position;
                    Vector3 sb = b.Position - actual.Bones[shoulderId].Position;
                    AddMetric(major ? "armJointRelativeErrorOverReach" : "fingerJointRelativeErrorOverReach", (sa - sb).magnitude / reach);
                    AddMetric(major ? "armJointGlobalErrorMeters" : "fingerJointGlobalErrorMeters", Vector3.Distance(a.Position, b.Position));
                }
                foreach (bool left in new[] { true, false })
                {
                    var u = left ? HumanBodyBones.LeftUpperArm : HumanBodyBones.RightUpperArm;
                    var e = left ? HumanBodyBones.LeftLowerArm : HumanBodyBones.RightLowerArm;
                    var w = left ? HumanBodyBones.LeftHand : HumanBodyBones.RightHand;
                    AddMetric("upperSegmentDirectionDegrees", Direction(source.Bones[e].Position - source.Bones[u].Position,
                        actual.Bones[e].Position - actual.Bones[u].Position));
                    AddMetric("forearmSegmentDirectionDegrees", Direction(source.Bones[w].Position - source.Bones[e].Position,
                        actual.Bones[w].Position - actual.Bones[e].Position));
                }
                return worst;
            }
            private void AddMetric(string key, double value)
            {
                if (!metrics.TryGetValue(key, out Stats stats)) metrics.Add(key, stats = new Stats());
                stats.Add(value);
            }
            public JObject Json()
            {
                var result = new JObject(metrics.Select(pair => new JProperty(pair.Key, pair.Value.Json())));
                result["perBoneLocalDegrees"] = new JObject(bones.Select(pair => new JProperty(pair.Key, pair.Value.Json())));
                return result;
            }
        }
        private sealed class Stats
        {
            private readonly List<double> values = new();
            public void Add(double value)
            {
                if (double.IsNaN(value) || double.IsInfinity(value)) throw new InvalidDataException("Nonfinite audit metric");
                values.Add(value);
            }
            public JObject Json()
            {
                if (values.Count == 0) return new JObject { ["count"] = 0 };
                double[] sorted = values.OrderBy(value => value).ToArray();
                return new JObject { ["count"] = values.Count, ["mean"] = values.Average(), ["max"] = sorted.Last(),
                    ["p95"] = sorted[(int)Math.Floor((sorted.Length - 1) * .95)] };
            }
        }
        private static bool IsMajor(HumanBodyBones bone) => bone is HumanBodyBones.LeftShoulder or HumanBodyBones.RightShoulder or
            HumanBodyBones.LeftUpperArm or HumanBodyBones.RightUpperArm or HumanBodyBones.LeftLowerArm or HumanBodyBones.RightLowerArm or
            HumanBodyBones.LeftHand or HumanBodyBones.RightHand;
        private static bool IsArm(HumanBodyBones bone) => IsMajor(bone) || bone.ToString().StartsWith("LeftThumb", StringComparison.Ordinal) ||
            bone.ToString().StartsWith("RightThumb", StringComparison.Ordinal) || new[] { "Index", "Middle", "Ring", "Little" }.Any(name => bone.ToString().Contains(name));
        private static double Angle(Quaternion a, Quaternion b)
        {
            double dot = (double)a.x * b.x + (double)a.y * b.y + (double)a.z * b.z + (double)a.w * b.w;
            double aa = (double)a.x * a.x + (double)a.y * a.y + (double)a.z * a.z + (double)a.w * a.w;
            double bb = (double)b.x * b.x + (double)b.y * b.y + (double)b.z * b.z + (double)b.w * b.w;
            return 2 * Math.Acos(Math.Min(1, Math.Abs(dot) / Math.Sqrt(aa * bb))) * 180 / Math.PI;
        }
        private static double Direction(Vector3 a, Vector3 b)
        {
            double dot = (double)a.x * b.x + (double)a.y * b.y + (double)a.z * b.z;
            double aa = (double)a.x * a.x + (double)a.y * a.y + (double)a.z * a.z;
            double bb = (double)b.x * b.x + (double)b.y * b.y + (double)b.z * b.z;
            return Math.Acos(Math.Min(1, Math.Max(-1, dot / Math.Sqrt(aa * bb)))) * 180 / Math.PI;
        }
        private static JArray Q(Quaternion q) => new(q.x, q.y, q.z, q.w);
        private static JArray V(Vector3 v) => new(v.x, v.y, v.z);
        private static string Sha(byte[] bytes)
        {
            using var hash = SHA256.Create();
            return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
    }
}
#endif
