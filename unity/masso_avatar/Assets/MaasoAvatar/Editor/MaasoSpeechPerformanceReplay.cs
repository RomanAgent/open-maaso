#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>
    /// Offline diagnostic of the production Receiver, scheduler, adapter and
    /// inertializer. Receipts and envelope are synthetic; no audio is played,
    /// no microphone/chat is recorded and no model/network is called.
    /// </summary>
    public static class MaasoSpeechPerformanceReplay
    {
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        private const float Epoch = 10f;
        private const int EnvelopeRate = 30;
        private const string Controller = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private static readonly HumanBodyBones[] MeasuredBones =
        {
            HumanBodyBones.Spine, HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm,
            HumanBodyBones.LeftHand, HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm,
            HumanBodyBones.RightHand,
        };

        public static void Run()
        {
            string output = Path.GetFullPath(Argument("-maasoSpeechReplayOutput", "Builds/Preview/SpeechPerformanceReplay"));
            Directory.CreateDirectory(output);
            bool render = !Environment.GetCommandLineArgs().Contains("-maasoSpeechReplayNoRender") &&
                SystemInfo.graphicsDeviceType != GraphicsDeviceType.Null;
            float[] envelope = SyntheticEnvelope();
            var sources = SourceFingerprints();
            var recipe = new JObject
            {
                ["schema"] = "maaso-synthetic-performance-replay-v1", ["seed"] = 1729,
                ["envelopeRate"] = EnvelopeRate, ["envelope"] = JArray.FromObject(envelope),
                ["receiptEverySeconds"] = .2, ["pauseAt"] = 2.2, ["resumeAt"] = 3.0,
                ["stopAt"] = 7.6, ["durationSeconds"] = 8.0,
                ["productionEntry"] = "UnityAvatarCommandReceiver.SyncSpeechPlaybackClock + SetConversationPhase + AdvanceSpeechPerformance",
                ["stepping"] = "Receiver.Update -> Animator.Update(dt) -> Receiver.AdvanceSpeechPerformance(now) -> production inertia Bind/Apply",
                ["clockInjection"] = "Only monotonic anchors receivedAt/phase timers are pinned; no pose, gesture choice or sample output is injected.",
                ["model"] = "bundled Joy", ["rootMotion"] = false,
                ["footIk"] = "controller-authored setting; never forced on", ["realAudioChatOrNetwork"] = false,
            };
            File.WriteAllText(Path.Combine(output, "synthetic-input.json"), recipe.ToString(Formatting.Indented));
            JObject run30 = Replay(30, envelope, output, false, true);
            JObject run60 = Replay(60, envelope, output, render, true);
            JObject repeat60 = Replay(60, envelope, output, false, true);
            JObject baseline30 = Replay(30, envelope, output, false, false);
            JObject baseline60 = Replay(60, envelope, output, false, false);
            bool deterministic = (string)run60["timelineSha256"] == (string)repeat60["timelineSha256"];
            JObject comparison30 = Compare(run30, baseline30), comparison60 = Compare(run60, baseline60);
            bool continuityImproved = (bool)comparison30["largestStepReduced"] && (bool)comparison60["largestStepReduced"];
            bool passed = deterministic && continuityImproved &&
                new[] { run30, run60, repeat60, baseline30, baseline60 }.All(run => (bool)run["passed"]);
            var receipt = new JObject
            {
                ["schema"] = "maaso-speech-performance-replay-receipt-v1",
                ["syntheticInputSha256"] = Hash(Encoding.UTF8.GetBytes(recipe.ToString(Formatting.None))),
                ["sourceFingerprintSha256"] = Hash(Encoding.UTF8.GetBytes(sources.ToString(Formatting.None))),
                ["sources"] = sources, ["same60FpsReplayHash"] = deterministic,
                ["runs"] = new JArray(run30, run60, repeat60, baseline30, baseline60), ["passed"] = passed,
                ["continuityGatePassed"] = continuityImproved,
                ["continuityComparison"] = new JArray(comparison30, comparison60),
                ["rendering"] = render ? "representative 60fps timeline frames captured using temporary per-frame baked meshes; PNG hashes must vary" : "skipped: disabled or null graphics device",
                ["bakedRenderBoundary"] = "BakeMesh copies the already-evaluated production pose only for static camera verification, avoiding same-Editor-tick skinning cache. No original mesh/material/transform asset is changed. This is not runtime rendering performance.",
                ["limits"] = "Editor simulation with synthetic playback receipts; not device audio/latency/penetration/performance measurement. Joy representative only; Joy normalized rig is covered separately by EditMode tests.",
            };
            File.WriteAllText(Path.Combine(output, "receipt.json"), receipt.ToString(Formatting.Indented));
            Debug.Log("[MaasoSpeechReplay] " + (passed ? "PASS " : "FAIL ") + Path.Combine(output, "receipt.json"));
            if (!passed) throw new InvalidOperationException("Synthetic production Receiver replay failed; inspect receipt.json.");
        }

        private static JObject Replay(int fps, float[] envelope, string output, bool render, bool useInertia)
        {
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject avatar = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            GameObject host = new("Synthetic speech replay receiver");
            Camera camera = null;
            try
            {
                avatar.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
                Animator animator = avatar.GetComponentInChildren<Animator>(true);
                if (animator == null || !animator.isHuman) throw new InvalidOperationException("Joy Humanoid unavailable.");
                animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(Controller);
                animator.applyRootMotion = false;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.Rebind(); animator.Update(0f);
                var receiver = host.AddComponent<UnityAvatarCommandReceiver>();
                Set(receiver, "avatarRoot", avatar.transform); Set(receiver, "animator", animator);
                Invoke(Get<object>(receiver, "localVisibility"), "SetVisible", true);
                Invoke(receiver, "SetConversationPhase", "{\"phase\":\"speaking\",\"sequence\":1}");
                object policy = Get<object>(receiver, "conversationMotion");
                // Freeze clock origins only. The validated Receiver command
                // above owns the phase and all production state transitions.
                foreach (string field in new[] { "desiredSince", "stableSince", "lastNow" }) Set(policy, field, Epoch);
                Set(policy, "nextChoiceAt", Epoch + AvatarConversationMotionPolicy.PhaseHysteresisSeconds);
                Set(policy, "nextFidgetAt", Epoch + AvatarConversationMotionPolicy.StableIdleBeforeFidgetSeconds);
                var clock = Get<AvatarSpeechPlaybackClock>(receiver, "speechPlaybackClock");
                var inertia = Get<AvatarUpperBodyInertializer>(receiver, "upperBodyInertia");
                var gestureAnimator = Get<AvatarSpeechGestureAnimator>(receiver, "speechGestureAnimator");
                var scheduler = Get<AvatarSpeechGestureScheduler>(receiver, "speechGestures");
                int layer = animator.GetLayerIndex(OpenAnnieMotionLibrary.UpperBodyLayerName);
                if (layer < 0) throw new InvalidOperationException("Official upper-body layer unavailable.");
                var transforms = MeasuredBones.Select(animator.GetBoneTransform).ToArray();
                if (transforms.Any(value => value == null)) throw new InvalidOperationException("Measured Humanoid bones unavailable.");
                Quaternion[] previous = transforms.Select(value => value.localRotation).ToArray();
                Vector3 initialRoot = avatar.transform.position;
                Quaternion initialRootRotation = avatar.transform.rotation;
                float rootTravel = 0f, rootTurn = 0f, largestStep = 0f, pauseWeight = 0f;
                JObject largestStepAt = null;
                int nonFinite = 0, accepted = 0, rejected = 0, accentCount = 0;
                long sequence = 0;
                int lastStroke = -1;
                string lastGesture = null;
                var transitions = new JArray();
                var snapshots = new JArray();
                var timeline = new JArray();
                var accents = new JArray();
                var renderedFrames = new JArray();
                if (render) camera = CreateCamera(avatar);
                int receiptStride = fps / 5;
                int pauseFrame = Mathf.RoundToInt(2.2f * fps), resumeFrame = 3 * fps, stopFrame = Mathf.RoundToInt(7.6f * fps);
                var captureFrames = new HashSet<int>(new[] { .4f, .9f, 1.4f, 2.4f, 3.2f, 5.5f, 7.9f }.Select(time => Mathf.RoundToInt(time * fps)));
                for (int frame = 0; frame <= 8 * fps; frame++)
                {
                    float wall = frame / (float)fps, now = Epoch + wall;
                    bool paused = frame >= pauseFrame && frame < resumeFrame;
                    float position = paused ? 2.2f : wall - (frame >= resumeFrame ? .8f : 0f);
                    if (frame <= stopFrame && frame % receiptStride == 0)
                    {
                        string state = frame == 0 ? "start" : frame == pauseFrame ? "pause" :
                            frame == resumeFrame ? "resume" : frame == stopFrame ? "stop" : "update";
                        var packet = new AvatarSpeechPlaybackClockPacket
                        {
                            protocolVersion = 1, playbackId = "synthetic-replay-audio", generation = 1,
                            turnId = "synthetic-turn", utteranceId = "synthetic-utterance", sequence = ++sequence,
                            state = state, positionMs = Mathf.RoundToInt(position * 1000), durationMs = 8000,
                            source = "wav", authoritative = true,
                            envelope = frame == 0 ? envelope : null, frameRate = frame == 0 ? EnvelopeRate : 0,
                        };
                        if ((bool)Invoke(receiver, "SyncSpeechPlaybackClock", packet)) accepted++; else rejected++;
                        Set(clock, "receivedAt", now);
                    }
                    // Same production order, with no fake pose or Animator IK.
                    Invoke(receiver, "Update");
                    animator.Update(frame == 0 ? 0f : 1f / fps);
                    Invoke(receiver, "AdvanceSpeechPerformance", now);
                    if (useInertia)
                    {
                        inertia.Bind(animator);
                        inertia.Apply(now, true);
                    }
                    rootTravel = Mathf.Max(rootTravel, Vector3.Distance(avatar.transform.position, initialRoot));
                    rootTurn = Mathf.Max(rootTurn, Quaternion.Angle(avatar.transform.rotation, initialRootRotation));
                    float weight = animator.GetLayerWeight(layer);
                    if (paused) pauseWeight = Mathf.Max(pauseWeight, weight);
                    var pose = new JArray();
                    for (int bone = 0; bone < transforms.Length; bone++)
                    {
                        Quaternion rotation = transforms[bone].localRotation;
                        if (!Finite(rotation)) nonFinite++;
                        float boneStep = Quaternion.Angle(previous[bone], rotation);
                        if (boneStep > largestStep)
                        {
                            largestStep = boneStep;
                            largestStepAt = new JObject
                            {
                                ["wallSeconds"] = wall, ["audioSeconds"] = position,
                                ["bone"] = MeasuredBones[bone].ToString(), ["speechId"] = gestureAnimator.ActiveId,
                                ["degrees"] = boneStep, ["paused"] = paused,
                                ["inertiaTransitioning"] = inertia.Transitioning,
                            };
                        }
                        previous[bone] = rotation;
                        pose.Add(new JArray(rotation.x, rotation.y, rotation.z, rotation.w));
                    }
                    string id = gestureAnimator.ActiveId;
                    if (id != lastGesture)
                    {
                        transitions.Add(new JObject { ["wallSeconds"] = wall, ["audioSeconds"] = position, ["id"] = id });
                        lastGesture = id;
                    }
                    var active = Get<OpenAnnieMotionLibrary.Entry>(scheduler, "active");
                    int stroke = Get<int>(scheduler, "reportedStroke");
                    // Evaluate the exact production gesture stage on a shallow
                    // diagnostic clone. EvaluateGesture only changes scalar
                    // bookkeeping; the live scheduler is never ticked twice.
                    // The clone retains the previous stroke watermark so its
                    // Sample reports the same new stroke offset as this frame.
                    AvatarSpeechGestureScheduler.Sample stageSample = AvatarSpeechGestureScheduler.Empty;
                    if (active != null)
                    {
                        object clone = typeof(object).GetMethod("MemberwiseClone", Private).Invoke(scheduler, null);
                        Set(clone, "reportedStroke", lastStroke);
                        stageSample = (AvatarSpeechGestureScheduler.Sample)Invoke(clone, "EvaluateGesture", clock.Position(now));
                    }
                    if (active == null) lastStroke = -1;
                    else if (stroke >= 0 && stroke != lastStroke)
                    {
                        float[] targets = Get<float[]>(scheduler, "targets");
                        accents.Add(new JObject { ["id"] = active.Id, ["strokeIndex"] = stroke,
                            ["audioSeconds"] = position, ["targetOnsetSeconds"] = targets[stroke],
                            ["sampleOffsetSeconds"] = position - targets[stroke] });
                        lastStroke = stroke; accentCount++;
                    }
                    string stage = paused ? "paused" : active == null ? "rest-or-silent" :
                        stageSample.Phase.ToString();
                    var sample = new JObject
                    {
                        ["wallSeconds"] = wall, ["audioSeconds"] = position, ["speechId"] = id,
                        ["stage"] = stage, ["layerWeight"] = weight, ["rotations"] = pose,
                        ["schedulerSamplePhase"] = stageSample.Phase.ToString(),
                        ["schedulerSampleStrokeIndex"] = stageSample.StrokeIndex,
                        ["schedulerSampleStrokeOffsetSeconds"] = stageSample.StrokeOffsetSeconds,
                        ["schedulerSampleClipSeconds"] = stageSample.ClipSeconds,
                    };
                    timeline.Add(sample);
                    if (captureFrames.Contains(frame))
                    {
                        snapshots.Add(sample.DeepClone());
                        if (camera != null)
                        {
                            string path = Path.Combine(output, $"joy-60-{wall:0.00}.png");
                            Render(camera, avatar, path);
                            renderedFrames.Add(new JObject { ["wallSeconds"] = wall, ["file"] = Path.GetFileName(path),
                                ["sha256"] = Hash(File.ReadAllBytes(path)) });
                        }
                    }
                }
                int distinctPngs = renderedFrames.Select(frame => (string)frame["sha256"]).Distinct().Count();
                bool variedImages = !render || (renderedFrames.Count > 1 && distinctPngs > 1);
                bool passed = rejected == 0 && accepted > 20 && nonFinite == 0 && variedImages &&
                    rootTravel < .0001f && rootTurn < .001f && pauseWeight < .0001f && accentCount > 0;
                return new JObject
                {
                    ["model"] = "Joy", ["fps"] = fps, ["useInertia"] = useInertia, ["frameCount"] = timeline.Count,
                    ["acceptedReceipts"] = accepted, ["rejectedReceipts"] = rejected,
                    ["nonFiniteBoneSamples"] = nonFinite, ["maximumRootTravelMeters"] = rootTravel,
                    ["maximumRootTurnDegrees"] = rootTurn, ["maximumPerFrameBoneStepDegrees"] = largestStep,
                    ["maximumStepLocation"] = largestStepAt,
                    ["maximumPausedLayerWeight"] = pauseWeight, ["accentCount"] = accentCount,
                    ["timelineSha256"] = Hash(Encoding.UTF8.GetBytes(timeline.ToString(Formatting.None))),
                    ["onsets"] = JArray.FromObject(scheduler.OnsetSeconds), ["transitions"] = transitions,
                    ["accents"] = accents, ["snapshots"] = snapshots, ["passed"] = passed,
                    ["renderedFrames"] = renderedFrames, ["distinctPngCount"] = distinctPngs,
                    ["representativeImagesVary"] = variedImages,
                };
            }
            finally
            {
                Object.DestroyImmediate(host);
                Object.DestroyImmediate(avatar);
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            }
        }

        private static JObject Compare(JObject corrected, JObject baseline)
        {
            float actual = (float)corrected["maximumPerFrameBoneStepDegrees"];
            float original = (float)baseline["maximumPerFrameBoneStepDegrees"];
            return new JObject
            {
                ["fps"] = corrected["fps"], ["sameInputsAndReceiverWithoutInertia"] = true,
                ["withInertiaMaxStepDegrees"] = actual, ["withoutInertiaMaxStepDegrees"] = original,
                ["largestStepReduced"] = actual < original,
                ["reductionPercent"] = original > 0f ? (original - actual) / original * 100f : 0f,
                ["withInertiaLocation"] = corrected["maximumStepLocation"].DeepClone(),
                ["withoutInertiaLocation"] = baseline["maximumStepLocation"].DeepClone(),
                ["interpretation"] = "Reports the actual simulated chain; a functional replay PASS does not assert all transitions are smooth. Pause/ownership releases intentionally have immediate priority.",
            };
        }

        private static float[] SyntheticEnvelope()
        {
            float[] values = Enumerable.Repeat(.08f, 8 * EnvelopeRate).ToArray();
            foreach (float onset in new[] { .9f, 1.9f, 3.7f, 4.7f, 5.9f, 6.7f })
                for (int frame = Mathf.RoundToInt(onset * EnvelopeRate); frame < Mathf.RoundToInt(onset * EnvelopeRate) + 5; frame++)
                    values[frame] = .8f;
            return values;
        }

        private static Camera CreateCamera(GameObject avatar)
        {
            var camera = new GameObject("Offline replay camera").AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = Color.white;
            camera.fieldOfView = 35f; camera.nearClipPlane = .05f; camera.farClipPlane = 30f;
            Bounds bounds = new(avatar.transform.position, Vector3.one);
            foreach (Renderer renderer in avatar.GetComponentsInChildren<Renderer>()) bounds.Encapsulate(renderer.bounds);
            float distance = Mathf.Max(2.5f, bounds.size.y / (2f * Mathf.Tan(17.5f * Mathf.Deg2Rad)) * 1.25f);
            camera.transform.position = bounds.center + Vector3.forward * distance;
            camera.transform.LookAt(bounds.center);
            RenderSettings.ambientMode = AmbientMode.Flat;
            RenderSettings.ambientLight = new Color(.75f, .75f, .75f);
            var light = new GameObject("Offline replay light").AddComponent<Light>();
            light.type = LightType.Directional; light.intensity = 1.5f;
            light.transform.rotation = Quaternion.Euler(25, -20, 0);
            return camera;
        }

        private static void Render(Camera camera, GameObject avatar, string path)
        {
            RenderTexture previous = RenderTexture.active;
            RenderTexture oldTarget = camera.targetTexture;
            var target = new RenderTexture(512, 768, 24, RenderTextureFormat.ARGB32);
            var pixels = new Texture2D(512, 768, TextureFormat.RGB24, false);
            var bakedObjects = new List<(GameObject gameObject, Mesh mesh)>();
            var originalEnabled = new Dictionary<SkinnedMeshRenderer, bool>();
            try
            {
                // Repeated camera.Render inside one editor tick may reuse a
                // stale GPU skinning buffer. Bake each CURRENT evaluated pose
                // into temporary static meshes for this capture only.
                foreach (SkinnedMeshRenderer source in avatar.GetComponentsInChildren<SkinnedMeshRenderer>())
                {
                    if (!source.enabled || source.sharedMesh == null || source.forceRenderingOff) continue;
                    var mesh = new Mesh { name = "Synthetic replay frame mesh", hideFlags = HideFlags.HideAndDontSave };
                    var baked = new GameObject("Synthetic replay frame renderer") { hideFlags = HideFlags.HideAndDontSave,
                        layer = source.gameObject.layer };
                    bakedObjects.Add((baked, mesh));
                    source.BakeMesh(mesh);
                    baked.transform.SetParent(source.transform, false);
                    baked.AddComponent<MeshFilter>().sharedMesh = mesh;
                    var renderer = baked.AddComponent<MeshRenderer>();
                    renderer.sharedMaterials = source.sharedMaterials;
                    renderer.shadowCastingMode = source.shadowCastingMode;
                    renderer.receiveShadows = source.receiveShadows;
                    renderer.lightProbeUsage = source.lightProbeUsage;
                    renderer.reflectionProbeUsage = source.reflectionProbeUsage;
                    renderer.probeAnchor = source.probeAnchor;
                    renderer.sortingLayerID = source.sortingLayerID;
                    renderer.sortingOrder = source.sortingOrder;
                    var properties = new MaterialPropertyBlock();
                    source.GetPropertyBlock(properties); renderer.SetPropertyBlock(properties);
                    originalEnabled[source] = source.enabled;
                    source.enabled = false;
                }
                camera.targetTexture = target;
                camera.Render();
                RenderTexture.active = target;
                pixels.ReadPixels(new Rect(0, 0, 512, 768), 0, 0); pixels.Apply();
                File.WriteAllBytes(path, pixels.EncodeToPNG());
            }
            finally
            {
                camera.targetTexture = oldTarget; RenderTexture.active = previous;
                foreach (var pair in originalEnabled) if (pair.Key != null) pair.Key.enabled = pair.Value;
                foreach (var baked in bakedObjects)
                {
                    Object.DestroyImmediate(baked.gameObject);
                    Object.DestroyImmediate(baked.mesh);
                }
                Object.DestroyImmediate(pixels); Object.DestroyImmediate(target);
            }
        }

        private static JArray SourceFingerprints()
        {
            var paths = new[]
            {
                "Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs",
                "Assets/MaasoAvatar/Scripts/AvatarSpeechPlaybackClock.cs",
                "Assets/MaasoAvatar/Scripts/AvatarSpeechGestureScheduler.cs",
                "Assets/MaasoAvatar/Scripts/AvatarSpeechGestureAnimator.cs",
                "Assets/MaasoAvatar/Scripts/AvatarUpperBodyInertializer.cs",
                "Assets/MaasoAvatar/Scripts/AvatarConversationMotionPolicy.cs",
                "Assets/MaasoAvatar/Scripts/OpenAnnieMotionPlayback.cs",
                "Assets/MaasoAvatar/Editor/MaasoSpeechPerformanceReplay.cs",
                Controller, "Assets/MaasoAvatar/Resources/OpenAnnieMotionLibrary.asset",
            };
            return new JArray(paths.Select(path => new JObject { ["path"] = path,
                ["sha256"] = Hash(File.ReadAllBytes(Path.Combine(Application.dataPath, path.Substring("Assets/".Length)))) }));
        }
        private static bool Finite(Quaternion value) => !float.IsNaN(value.x + value.y + value.z + value.w) &&
            !float.IsInfinity(value.x + value.y + value.z + value.w);
        private static string Hash(byte[] value)
        {
            using var sha = SHA256.Create();
            return string.Concat(sha.ComputeHash(value).Select(octet => octet.ToString("x2")));
        }
        private static object Invoke(object target, string name, params object[] args) =>
            target.GetType().GetMethod(name, Private | BindingFlags.Public).Invoke(target, args);
        private static T Get<T>(object target, string name) => (T)target.GetType().GetField(name, Private).GetValue(target);
        private static void Set(object target, string name, object value) => target.GetType().GetField(name, Private).SetValue(target, value);
        private static string Argument(string name, string fallback)
        {
            string[] args = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(args, name);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : fallback;
        }
    }
}
#endif
