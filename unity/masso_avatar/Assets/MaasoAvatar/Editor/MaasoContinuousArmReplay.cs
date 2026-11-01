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
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Continuous ACTUAL receiver/VRM/skinning-input replay. All inputs are synthetic;
    /// no audio, microphone, model calls or original assets are written. A separate source-only
    /// comparator deliberately omits overlays; full runs call the production frame entry.</summary>
    public static class MaasoContinuousArmReplay
    {
        private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
        private const string Controller = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const float CueAt = .8f, ClearAt = 4.3f, AudioStopAt = 5.6f, Duration = 8f;
        private static readonly HumanBodyBones[] Measured = { HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm,
            HumanBodyBones.LeftHand, HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand };

        public static void Run()
        {
            string output = Path.GetFullPath(Argument("-maasoContinuousArmOutput", "/private/tmp/maaso-continuous-arm-replay"));
            Directory.CreateDirectory(output);
            string[] models = Argument("-maasoContinuousArmModels", "joy,joy_runtime").Split(',');
            string[] scenarios = Argument("-maasoContinuousArmScenarios", "default_idle,speech_release").Split(',');
            bool render = !Environment.GetCommandLineArgs().Contains("-maasoContinuousArmNoRender") && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Null;
            var runs = new JArray();
            foreach (string model in models) foreach (string scenario in scenarios)
                foreach (string variant in new[] { "guard-on", "guard-off", "source-only" })
                    runs.Add(RunCase(model == "matt", variant == "guard-on", variant == "source-only", 60, model == "joy_runtime" ? "runtime_" + scenario : scenario, output, render));
            File.WriteAllText(Path.Combine(output, "receipt.json"), new JObject {
                ["schema"] = "maaso-continuous-arm-replay-v1", ["sources"] = Sources(), ["runs"] = runs,
                ["fullPipeline"] = "Receiver.Update -> Animator.Update(dt) -> Receiver.AdvancePresentationFrame(now,utc) -> Vrm.Runtime.Process -> AvatarRigifyArmDeformation.ApplyAfterVrm",
                ["clockBoundary"] = "Synthetic authoritative playback receipt every frame. Only clock receipt and remaining body-lease UTC anchors are rebased; no pose, IK target, guard output or gesture choice is injected. Host BODY-clear delivered at synthetic lease expiry.",
                ["limit"] = "Editor continuous-pose diagnostic, not physical-device audio/performance or garment collision certification. Source-only comparator intentionally omits inertia/micro/collision while retaining actual scheduler, Animator, VRM and Rigify.",
            }.ToString());
            Debug.Log("[MaasoContinuousArmReplay] Wrote " + output);
        }

        /// <summary>Public solely for focused EditMode regression fixtures. Does not assert a
        /// visual-quality verdict; reports complete stage and correction discontinuities.</summary>
        public static JObject RunCase(bool matt, bool guardEnabled, bool sourceOnly, int fps,
            string scenario, string output, bool render)
        {
            bool runtimeVrm = !matt && scenario.StartsWith("runtime_", StringComparison.Ordinal);
            string requestedScenario = scenario;
            if (runtimeVrm) scenario = scenario.Substring("runtime_".Length);
            if (fps < 15 || fps > 120 || scenario is not ("default_idle" or "annie_idle_c" or "speech_release"))
                throw new ArgumentException("Unknown bounded replay configuration");
            Directory.CreateDirectory(output);
            UnityEngine.Random.State previousRandom = UnityEngine.Random.state;
            UnityEngine.Random.InitState(1729);
            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            string label = (matt ? "matt" : runtimeVrm ? "joy-runtime" : "joy") + "-" + scenario + "-" + (sourceOnly ? "source-only" : guardEnabled ? "guard-on" : "guard-off");
            if (matt) throw new ArgumentException("The official male avatar has been retired.", nameof(matt));
            GameObject model = Object.Instantiate(AssetDatabase.LoadAssetAtPath<GameObject>("Assets/MaasoAvatar/Models/Default/Joy.vrm"));
            model.transform.SetPositionAndRotation(Vector3.zero, Quaternion.identity);
            var materials = model.GetComponentsInChildren<Renderer>(true).ToDictionary(r => r, r => r.sharedMaterials);
            GameObject host = new("Continuous actual arm replay"); Camera camera = null;
            var timeline = new JArray(); var toggles = new JArray(); var images = new JArray();
            try
            {
                Animator animator = model.GetComponentInChildren<Animator>(true);
                animator.runtimeAnimatorController = AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(Controller);
                animator.applyRootMotion = false; animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                Vrm10Instance vrm = model.GetComponentInChildren<Vrm10Instance>(true);
                if (vrm != null)
                {
                    vrm.enabled = false;
                    if (runtimeVrm)
                    {
                        // Mirror the production MaasoVrmLoader Generate factory
                        // option BEFORE Runtime is first accessed. This changes
                        // model construction, never a sampled pose or bone angle.
                        if (typeof(Vrm10Instance).GetField("m_runtime", Private).GetValue(vrm) != null)
                            throw new InvalidOperationException("Runtime VRM factory option must precede initialization");
                        typeof(Vrm10Instance).GetField("m_useControlRig", Private).SetValue(vrm, true);
                    }
                }
                var receiver = host.AddComponent<UnityAvatarCommandReceiver>();
                Set(receiver, "avatarRoot", model.transform); Set(receiver, "bundledAvatarRoot", model.transform);
                Invoke(receiver, "BindAvatarRoot", model.transform);
                animator = Get<Animator>(receiver, "animator");
                animator.Rebind(); animator.Play("Base Layer." + (scenario == "annie_idle_c" ? "annie_idle_c" : "idle_shrug"), 0, 0f);
                animator.Update(0f); vrm?.Runtime.Process();
                Invoke(Get<object>(receiver, "localVisibility"), "SetVisible", true);
                var guard = Get<AvatarFreeGestureCollisionGuard>(receiver, "freeGestureCollision");
                bool calibrated = guard.Bound; string calibration = guard.BindingDiagnostic;
                if (!guardEnabled || sourceOnly) guard.Bind(null, null);
                var deformation = Get<AvatarRigifyArmDeformation>(receiver, "activeArmDeformation");
                var elbowCorrectives = model.GetComponentInChildren<AvatarJoyElbowCorrectives>(true);
                deformation?.ApplyAfterVrm(); elbowCorrectives?.ApplyAfterVrm();
                Transform Raw(HumanBodyBones id) => vrm != null ? vrm.Humanoid.GetBoneTransform(id) : animator.GetBoneTransform(id);
                Transform[] raw = Measured.Select(Raw).ToArray();
                Transform[] inputBones = Measured.Select(animator.GetBoneTransform).ToArray();
                if (raw.Any(t => t == null) || inputBones.Any(t => t == null)) throw new InvalidOperationException("Actual measured arm bones unavailable");
                var clock = Get<AvatarSpeechPlaybackClock>(receiver, "speechPlaybackClock");
                var player = Get<AvatarSpeechGestureAnimator>(receiver, "speechGestureAnimator");
                MethodInfo frameEntry = receiver.GetType().GetMethod("AdvancePresentationFrame", Private, null, new[] { typeof(float), typeof(long) }, null);
                bool syntheticFrameTime = frameEntry != null;
                float origin = Time.realtimeSinceStartup; long utcOrigin = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                float[] envelope = Envelope(); long audioSequence = 0, bodyTicket = 0;
                var previous = Pose(raw); Vector3[] previousSource = null, previousResidual = null;
                var metrics = new Metrics(); bool priorCorrection = false, priorUnresolved = false;
                int correctionFrames = 0, unresolvedFrames = 0, correctionToggles = 0, rejectedPackets = 0;
                Vector3 rootPosition = model.transform.position; Quaternion rootRotation = model.transform.rotation;
                Vector3[] worstPositions = null; Quaternion[] worstRotations = null;
                Dictionary<SkinnedMeshRenderer, float[]> worstMorphs = null;
                Transform[] all = model.GetComponentsInChildren<Transform>(true);
                float worstScore = -1f; int worstFrame = 0;
                var fixedFrames = new HashSet<int>(new[] { 1.5f, 3.2f, 4.35f, 6.5f }.Select(t => Mathf.RoundToInt(t * fps)));
                if (render && SystemInfo.graphicsDeviceType != GraphicsDeviceType.Null) camera = CameraFor(model);
                if (scenario == "speech_release") SetOwner(receiver);
                for (int frame = 0; frame <= Mathf.RoundToInt(Duration * fps); frame++)
                {
                    float wall = frame / (float)fps;
                    float now = syntheticFrameTime ? origin + wall : Time.realtimeSinceStartup;
                    long utc = utcOrigin + Mathf.RoundToInt(wall * 1000f);
                    Invoke(receiver, "Update");
                    if (scenario == "speech_release" && frame == Mathf.RoundToInt(CueAt * fps))
                        BodyTicket(receiver, ++bodyTicket, false);
                    // A clock-domain adapter, not a refreshed authorization:
                    // preserve the SAME selected remaining lease at this virtual frame.
                    if (scenario == "speech_release" && wall >= CueAt && wall < ClearAt && Get<string>(receiver, "performanceCueGesture") != null)
                        Set(receiver, "performanceCueDeadlineMs", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + Mathf.Max(1, Mathf.RoundToInt((ClearAt - wall) * 1000f)));
                    if (scenario == "speech_release" && frame == Mathf.RoundToInt(ClearAt * fps))
                        BodyTicket(receiver, ++bodyTicket, true);
                    if (scenario == "speech_release" && wall >= CueAt && wall <= AudioStopAt)
                    {
                        bool first = frame == Mathf.RoundToInt(CueAt * fps), stop = frame == Mathf.RoundToInt(AudioStopAt * fps);
                        var packet = new AvatarSpeechPlaybackClockPacket { protocolVersion = 1, playbackId = "continuous-arm-audio",
                            generation = 1, turnId = "continuous-arm-turn", utteranceId = "continuous-arm-utterance",
                            sequence = ++audioSequence, state = first ? "start" : stop ? "stop" : "update",
                            positionMs = Mathf.RoundToInt((wall - CueAt) * 1000f), durationMs = 6000,
                            source = "wav", authoritative = true, envelope = first ? envelope : null, frameRate = first ? 30 : 0 };
                        // Sync itself samples Unity's real clock. Rebase its previous
                        // anchor into that domain before delivering this synthetic
                        // cursor, then return the anchor to the frame-hook domain.
                        if (!first && clock.Active) Set(clock, "receivedAt", Time.realtimeSinceStartup - 1f / fps);
                        if (!(bool)Invoke(receiver, "SyncSpeechPlaybackClock", packet)) rejectedPackets++;
                        Set(clock, "receivedAt", now);
                    }
                    animator.Update(frame == 0 ? 0f : 1f / fps);
                    PoseSample source = Pose(inputBones);
                    if (sourceOnly)
                    {
                        Get<OpenAnnieMotionPlayback>(receiver, "annieMotion").Advance(animator, now, false);
                        Invoke(receiver, "AdvanceSpeechPerformance", now);
                        Invoke(receiver, "UpdateIdlePose");
                    }
                    else if (frameEntry != null) frameEntry.Invoke(receiver, new object[] { now, utc });
                    else Invoke(receiver, "LateUpdate");
                    PoseSample overlays = Pose(inputBones);
                    vrm?.Runtime.Process();
                    PoseSample vrmRaw = Pose(raw);
                    deformation?.ApplyAfterVrm();
                    // Unity invokes this model-scoped helper at order11020.
                    // Manual editor frames must execute the same post-Rigify
                    // skin-weight stage before BakeMesh/rendering evidence.
                    elbowCorrectives?.ApplyAfterVrm();
                    PoseSample rendered = Pose(raw);
                    bool corrected = guard.CorrectedArms > 0, unresolved = guard.Unresolved;
                    if (corrected) correctionFrames++; if (unresolved) unresolvedFrames++;
                    if (frame > 0 && corrected != priorCorrection) correctionToggles++;
                    if (frame > 0 && (corrected != priorCorrection || unresolved != priorUnresolved))
                        toggles.Add(new JObject { ["frame"] = frame, ["seconds"] = wall, ["corrected"] = corrected,
                            ["unresolved"] = unresolved, ["speechId"] = player.ActiveId, ["clearance"] = JsonFinite(guard.LastMinimumClearance) });
                    priorCorrection = corrected; priorUnresolved = unresolved;
                    float step = 0f, residualStep = 0f;
                    var residual = new Vector3[raw.Length];
                    for (int i = 0; i < raw.Length; i++)
                    {
                        residual[i] = rendered.Positions[i] - source.Positions[i];
                        if (frame > 0 && wall >= .3f)
                        {
                            float distance = Vector3.Distance(rendered.Positions[i], previous.Positions[i]);
                            float angle = Quaternion.Angle(rendered.Rotations[i], previous.Rotations[i]);
                            float correctionStep = previousResidual == null ? 0f : Vector3.Distance(residual[i], previousResidual[i]);
                            float sourceStep = previousSource == null ? 0f : Vector3.Distance(source.Positions[i], previousSource[i]);
                            metrics.Record(i, frame, wall, distance, angle, correctionStep, sourceStep, corrected, unresolved, player.ActiveId);
                            step = Mathf.Max(step, distance); residualStep = Mathf.Max(residualStep, correctionStep);
                        }
                        if (!Finite(rendered.Positions[i]) || !Finite(rendered.Rotations[i])) metrics.NonFinite++;
                    }
                    float score = Mathf.Max(step, residualStep);
                    if (wall >= .3f && score > worstScore)
                    {
                        worstScore = score; worstFrame = frame;
                        worstPositions = all.Select(t => t.localPosition).ToArray(); worstRotations = all.Select(t => t.localRotation).ToArray();
                        worstMorphs = model.GetComponentsInChildren<SkinnedMeshRenderer>(true).ToDictionary(skin => skin,
                            skin => Enumerable.Range(0, skin.sharedMesh.blendShapeCount).Select(skin.GetBlendShapeWeight).ToArray());
                    }
                    var row = new JObject { ["frame"] = frame, ["seconds"] = wall, ["stageSource"] = source.Json(), ["stageOverlays"] = overlays.Json(),
                        ["stageVrmRaw"] = vrmRaw.Json(), ["stageRenderedRaw"] = rendered.Json(), ["guardCorrectedArms"] = guard.CorrectedArms, ["guardUnresolved"] = unresolved,
                        ["clearance"] = JsonFinite(guard.LastMinimumClearance), ["speechId"] = player.ActiveId,
                        ["baseStateHash"] = animator.GetCurrentAnimatorStateInfo(0).shortNameHash, ["transition"] = animator.IsInTransition(0),
                        ["bodyCue"] = Get<string>(receiver, "performanceCueGesture"), ["maximumJointStepMeters"] = step, ["maximumResidualStepMeters"] = residualStep };
                    timeline.Add(row); previous = rendered; previousSource = source.Positions; previousResidual = residual;
                    if (camera != null && fixedFrames.Contains(frame)) Capture(camera, model, output, label + "-" + wall.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture), images);
                }
                if (camera != null && worstPositions != null)
                {
                    for (int i = 0; i < all.Length; i++) { all[i].localPosition = worstPositions[i]; all[i].localRotation = worstRotations[i]; }
                    if (worstMorphs != null) foreach (var morph in worstMorphs)
                        for (int index = 0; index < morph.Value.Length; index++) morph.Key.SetBlendShapeWeight(index, morph.Value[index]);
                    Capture(camera, model, output, label + "-worst", images);
                }
                string timelinePath = Path.Combine(output, label + "-timeline.json"); File.WriteAllText(timelinePath, timeline.ToString(Formatting.None));
                var result = new JObject { ["label"] = label, ["model"] = matt ? "Matt" : "Joy", ["fps"] = fps, ["frames"] = timeline.Count,
                    ["scenario"] = requestedScenario, ["runtimeVrmFactoryGenerate"] = runtimeVrm, ["guardEnabled"] = guardEnabled && !sourceOnly, ["sourceOnlyComparator"] = sourceOnly,
                    ["modelProbeCalibrated"] = calibrated, ["probeCalibration"] = calibration, ["rigifyApplied"] = deformation != null && deformation.Bound,
                    ["joyElbowCorrectivesApplied"] = elbowCorrectives != null && elbowCorrectives.Bound,
                    ["joyElbowCorrectivesBindingFailure"] = elbowCorrectives != null ? elbowCorrectives.LastFailure : null,
                    ["vrmProcessApplied"] = vrm != null, ["normalizedControlRig"] = vrm != null && vrm.Runtime.ControlRig != null,
                    ["animatorInputBoneNames"] = JArray.FromObject(inputBones.Select(t => t.name)), ["renderedRawBoneNames"] = JArray.FromObject(raw.Select(t => t.name)),
                    ["sourcePoseSpace"] = "Animator-mapped Humanoid input (normalized on generated VRM); final stage is actual raw skin joints",
                    ["sourceInputSha256"] = Sha(Encoding.UTF8.GetBytes(new JArray(timeline.Select(row => row["stageSource"].DeepClone())).ToString(Formatting.None))),
                    ["completeProductionFrameEntry"] = !sourceOnly && syntheticFrameTime, ["fallbackWallClockFrame"] = !syntheticFrameTime,
                    ["rejectedPlaybackPackets"] = rejectedPackets, ["correctionFrames"] = correctionFrames, ["unresolvedFrames"] = unresolvedFrames,
                    ["correctionToggleCount"] = correctionToggles, ["toggles"] = toggles, ["worstFrame"] = worstFrame,
                    ["metrics"] = metrics.Json(), ["images"] = images, ["timelineFile"] = timelinePath, ["timelineSha256"] = Sha(File.ReadAllBytes(timelinePath)),
                    ["rootTravelMeters"] = Vector3.Distance(model.transform.position, rootPosition), ["rootTurnDegrees"] = Quaternion.Angle(model.transform.rotation, rootRotation) };
                File.WriteAllText(Path.Combine(output, label + "-receipt.json"), result.ToString());
                return result;
            }
            finally
            {
                Object.DestroyImmediate(host);
                var borrowed = new HashSet<Material>(materials.Values.SelectMany(m => m));
                Material[] clones = materials.Keys.Where(r => r != null).SelectMany(r => r.sharedMaterials).Where(m => m != null && !borrowed.Contains(m) && !AssetDatabase.Contains(m)).Distinct().ToArray();
                foreach (var pair in materials) if (pair.Key != null) pair.Key.sharedMaterials = pair.Value;
                foreach (Material clone in clones) Object.DestroyImmediate(clone);
                Vrm10Instance vrm = model.GetComponentInChildren<Vrm10Instance>(true);
                if (vrm != null && vrm.Runtime.ControlRig != null) { Object.DestroyImmediate(vrm.Runtime.ControlRig.ControlRigAnimator.avatar); Transform controls = vrm.transform.Find("Runtime Control Rig"); if (controls != null) Object.DestroyImmediate(controls.gameObject); }
                Object.DestroyImmediate(model); EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
                UnityEngine.Random.state = previousRandom;
            }
        }

        private sealed class PoseSample
        {
            public Vector3[] Positions; public Quaternion[] Rotations;
            public JObject Json() => new() { ["positions"] = new JArray(Positions.Select(p => new JArray(p.x, p.y, p.z))),
                ["rotations"] = new JArray(Rotations.Select(q => new JArray(q.x, q.y, q.z, q.w))) };
        }
        private static PoseSample Pose(Transform[] bones) => new() { Positions = bones.Select(t => t.position).ToArray(), Rotations = bones.Select(t => t.rotation).ToArray() };
        private sealed class Metrics
        {
            public int NonFinite;
            private float maxStep, maxAngle, maxResidual, maxSource;
            private JObject stepAt, residualAt;
            private readonly Dictionary<string, float> windowMax = new();
            public void Record(int bone, int frame, float seconds, float step, float angle, float residual, float source, bool corrected, bool unresolved, string speech)
            {
                JObject Point() => new() { ["frame"] = frame, ["seconds"] = seconds, ["bone"] = Measured[bone].ToString(), ["stepMeters"] = step,
                    ["residualStepMeters"] = residual, ["guardCorrected"] = corrected, ["guardUnresolved"] = unresolved, ["speechId"] = speech };
                if (step > maxStep) { maxStep = step; stepAt = Point(); }
                if (residual > maxResidual) { maxResidual = residual; residualAt = Point(); }
                maxAngle = Mathf.Max(maxAngle, angle); maxSource = Mathf.Max(maxSource, source);
                string window = seconds < CueAt ? "initial-idle" : seconds < ClearAt ? "lease-active" : seconds < AudioStopAt ? "lease-released-audio-active" : "post-audio-idle";
                windowMax[window] = Mathf.Max(windowMax.TryGetValue(window, out float previous) ? previous : 0f, residual);
            }
            public JObject Json() => new() { ["maximumJointStepMeters"] = maxStep, ["maximumRawBoneStepDegrees"] = maxAngle,
                ["maximumOverlayResidualStepMeters"] = maxResidual, ["maximumSourceJointStepMeters"] = maxSource,
                ["maximumJointStepAt"] = stepAt, ["maximumOverlayResidualAt"] = residualAt, ["nonFiniteSamples"] = NonFinite,
                ["windowResidualMaxima"] = JObject.FromObject(windowMax) };
        }
        private static float[] Envelope()
        {
            float[] result = Enumerable.Repeat(.2f, 180).ToArray();
            foreach (var range in new[] { (1.2f, 1.55f), (2.65f, 2.95f), (4.4f, 4.65f) })
                for (int i = Mathf.RoundToInt(range.Item1 * 30); i < Mathf.RoundToInt(range.Item2 * 30); i++) result[i] = 0f;
            foreach (float accent in new[] { .4f, .9f, 1.9f, 3.1f, 3.8f, 4.9f })
                for (int i = Mathf.RoundToInt(accent * 30); i < Mathf.RoundToInt(accent * 30) + 3; i++) result[i] = .8f;
            return result;
        }
        private static void SetOwner(object receiver)
        { Set(receiver, "avatarArbiterOwnerToken", new string('A', 43)); Set(receiver, "avatarArbiterAccountGeneration", 7L); Set(receiver, "avatarArbiterRendererGeneration", 1L); Set(receiver, "avatarArbiterRendererGenerationHighWater", 1L); }
        private static void BodyTicket(object receiver, long ticket, bool clear)
        {
            long utc = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            string payload = clear ? "{\"channel\":\"bodyGesture\",\"clear\":true}" : new JObject { ["channel"] = "bodyGesture", ["gesture"] = "speech",
                ["energy"] = "gentle", ["emotion"] = "neutral", ["intensity"] = .65f, ["leaseExpiresAtEpochMs"] = utc + 3500 }.ToString(Formatting.None);
            Invoke(receiver, "DispatchAvatarArbiterCommand", new JObject { ["protocolVersion"] = 1, ["requestId"] = "continuous-body-" + ticket, ["ticket"] = ticket,
                ["rendererId"] = "continuous-renderer", ["ownerToken"] = new string('A', 43), ["commitToken"] = new string('C', 43), ["accountGeneration"] = 7,
                ["rendererGeneration"] = 1, ["channel"] = "bodyGesture", ["fingerprint"] = clear ? "" : "0123456789abcdef", ["payloadJson"] = payload,
                ["payloadSha256"] = Sha(Encoding.UTF8.GetBytes(payload)), ["deadlineEpochMs"] = utc + 500, ["clearsChannel"] = clear }.ToString(Formatting.None));
        }
        private static Camera CameraFor(GameObject model)
        {
            var camera = (Camera)typeof(MaasoSpeechPerformanceReplay).GetMethod("CreateCamera", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { model });
            if (Environment.GetCommandLineArgs().Contains("-maasoContinuousArmCloseup"))
            {
                camera.fieldOfView = 33f;
                camera.transform.position = model.transform.position + new Vector3(0f, 1.25f, 2f);
                camera.transform.LookAt(model.transform.position + new Vector3(0f, 1.25f, 0f));
                RenderSettings.ambientLight = new Color(.45f, .45f, .45f);
            }
            return camera;
        }
        private static void Capture(Camera camera, GameObject model, string output, string label, JArray images)
        {
            string path = Path.Combine(output, label + ".png");
            typeof(MaasoSpeechPerformanceReplay).GetMethod("Render", BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, new object[] { camera, model, path });
            images.Add(new JObject { ["file"] = path, ["sha256"] = Sha(File.ReadAllBytes(path)) });
        }
        private static JArray Sources() => new(new[] { Controller, "Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs",
            "Assets/MaasoAvatar/Scripts/AvatarFreeGestureCollisionGuard.cs", "Assets/MaasoAvatar/Scripts/AvatarConversationalMicroMotion.cs",
            "Assets/MaasoAvatar/Scripts/AvatarUpperBodyInertializer.cs", "Assets/MaasoAvatar/Scripts/AvatarRigifyArmDeformation.cs",
            "Assets/MaasoAvatar/Scripts/AvatarJoyElbowCorrectives.cs", "Assets/Resources/MaasoAvatar/joy_elbow_correctives.json",
            "Assets/MaasoAvatar/Scripts/AvatarSpeechGestureScheduler.cs", "Assets/MaasoAvatar/Editor/MaasoContinuousArmReplay.cs" }
            .Select(path => new JObject { ["path"] = path, ["sha256"] = Sha(File.ReadAllBytes(Path.Combine(Application.dataPath, path.Substring(7)))) }));
        private static JToken JsonFinite(float value) => float.IsNaN(value) || float.IsInfinity(value) ? JValue.CreateNull() : new JValue(value);
        private static bool Finite(Vector3 p) => !float.IsNaN(p.x + p.y + p.z) && !float.IsInfinity(p.x + p.y + p.z);
        private static bool Finite(Quaternion q) => !float.IsNaN(q.x + q.y + q.z + q.w) && !float.IsInfinity(q.x + q.y + q.z + q.w);
        private static object Invoke(object target, string name, params object[] args) => target.GetType().GetMethod(name, Private | BindingFlags.Public).Invoke(target, args);
        private static T Get<T>(object target, string name) => (T)target.GetType().GetField(name, Private).GetValue(target);
        private static void Set(object target, string name, object value) => target.GetType().GetField(name, Private).SetValue(target, value);
        private static string Sha(byte[] bytes) { using var hash = SHA256.Create(); return string.Concat(hash.ComputeHash(bytes).Select(b => b.ToString("x2"))); }
        private static string Argument(string key, string fallback) { string[] args = Environment.GetCommandLineArgs(); int i = Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : fallback; }
    }
}
#endif
