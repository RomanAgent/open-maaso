#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using UnityEditor;
using UnityEditor.Animations;
using UnityEngine;
using Maaso.World;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Exercises the exact Receiver/after-frame presence path used by
    /// cold Home entry. It never changes presentation authority or timeouts.</summary>
    public static class OpenMaasoPresenceVerification
    {
        private const string Session = "OpenMaaso.VerifyPresence";
        private static readonly Queue<AvatarPresenceResult> pending = new();
        private static readonly List<string> receipts = new();
        private static readonly List<Sample> samples = new();
        private static UnityAvatarCommandReceiver receiver;
        private static Animator animator;
        private static RuntimeAnimatorController realController;
        private static AnimatorController missingController;
        private static AnimatorStateMachine missingMachine;
        private static Camera camera;
        private static RenderTexture target;
        private static string evidence, stage;
        private static int frames, sequence, settleFrames, sampleIndex, finishAtFrame;
        private static double started;
        private static float phaseStarted, recoverAtTime;
        private static Vector3 home;
        private static bool missingWalkObserved, cancelledEntryObserved;

        public static void BeginCapture()
        {
            if (Application.isBatchMode)
                throw new InvalidOperationException("Presence receipts require Game View; do not use -batchmode or -nographics.");
            MaasoDefaultAvatarSceneBuilder.RebuildScene();
            Type type = AppDomain.CurrentDomain.GetAssemblies()
                .Select(assembly => assembly.GetType("UnityEditor.GameView")).First(value => value != null);
            EditorWindow view = EditorWindow.GetWindow(type);
            view.Show(); view.Focus();
            SessionState.SetBool(Session, true);
            EditorApplication.EnterPlaymode();
        }

        [InitializeOnLoadMethod]
        private static void Resume()
        {
            if (!SessionState.GetBool(Session, false)) return;
            frames = sequence = settleFrames = sampleIndex = 0;
            stage = null; missingWalkObserved = cancelledEntryObserved = false;
            pending.Clear(); receipts.Clear(); samples.Clear();
            // Asset imports and Editor startup dialogs are not player frames.
            // Production packet deadlines below remain unchanged.
            started = -1;
            Application.logMessageReceived += ReadReceipt;
            EditorApplication.update += Tick;
        }

        private static void ReadReceipt(string message, string stack, LogType type)
        {
            const string prefix = "[UnityAvatar] command result ";
            if (!message.StartsWith(prefix, StringComparison.Ordinal)) return;
            var result = JsonUtility.FromJson<AvatarPresenceResult>(message.Substring(prefix.Length));
            if (result?.method == "transitionPresence" &&
                result.requestId?.StartsWith("public-presence-", StringComparison.Ordinal) == true)
                pending.Enqueue(result);
        }

        private static void Tick()
        {
            try
            {
                if (!EditorApplication.isPlaying) return;
                if (started < 0) started = EditorApplication.timeSinceStartup;
                if (EditorApplication.timeSinceStartup - started > 90)
                    throw new TimeoutException("Production presence path did not finish.");
                frames++;
                if (frames == 10)
                {
                    receiver = Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
                    Send("loadAvatar", "{\"requestId\":\"public-presence-load\",\"modelUrl\":\"unity://masso/avatar_agent\"}");
                    Send("setFraming", "{\"mode\":\"hero_full_body\"}");
                    Send("setLocalAvatarVisible", "{\"visible\":false}");
                }
                if (frames < 90) return;
                if (stage == null)
                {
                    evidence = Environment.GetEnvironmentVariable("OPEN_MAASO_PRESENCE_EVIDENCE");
                    if (string.IsNullOrWhiteSpace(evidence)) throw new InvalidOperationException("Set OPEN_MAASO_PRESENCE_EVIDENCE.");
                    evidence = Path.GetFullPath(evidence); Directory.CreateDirectory(evidence);
                    camera = Camera.main;
                    target = new RenderTexture(720, 1280, 24, RenderTextureFormat.ARGB32) { antiAliasing = 4 };
                    target.Create(); camera.targetTexture = target; camera.aspect = 720f / 1280f;
                    camera.GetComponent<FrontFullBodyCamera>().FrameNow();
                    animator = receiver.ActiveAvatarRoot.GetComponentInChildren<Animator>(true);
                    realController = animator.runtimeAnimatorController;
                    if (!animator.HasState(0, Animator.StringToHash("standard_walk")))
                        throw new InvalidOperationException("Bundled production controller still lacks standard_walk.");
                    home = receiver.ActiveAvatarRoot.position;
                    missingController = new AnimatorController { name = "DiagnosticIdleOnly" };
                    missingMachine = new AnimatorStateMachine();
                    AnimatorState idle = missingMachine.AddState("Idle");
                    idle.motion = AssetDatabase.LoadAssetAtPath<AnimationClip>("Assets/MaasoAvatar/Animations/Humanoid/OfflineIdle.anim");
                    missingMachine.defaultState = idle;
                    missingController.layers = new[] { new AnimatorControllerLayer { name = "Base Layer", defaultWeight = 1, stateMachine = missingMachine } };
                    animator.runtimeAnimatorController = missingController;
                    animator.Rebind(); animator.Play("Idle");
                    Phase("missing-prepare", "missing", "prepare");
                }

                if (stage == "real-enter" && sampleIndex < 3 &&
                    Time.realtimeSinceStartup - phaseStarted >= new[] { .25f, .55f, .85f }[sampleIndex])
                {
                    samples.Add(ReadSample());
                    Save("walk-" + (++sampleIndex) + ".png");
                }
                if (stage == "settle" && ++settleFrames >= 30)
                {
                    AssertHomeVisible(); Save("home-completed.png");
                    Phase("resume-prepare", "resume", "prepare");
                }
                if (stage == "cancel-enter" && Time.realtimeSinceStartup - phaseStarted >= .4f)
                    Phase("cancel-hold", "cancel", "holdHidden");
                if (stage == "cancel-settle" && Time.frameCount >= finishAtFrame && Time.realtimeSinceStartup >= recoverAtTime)
                {
                    AssertHomeVisible(); Save("home-after-cancel.png"); Finish(); return;
                }

                while (pending.Count > 0)
                {
                    AvatarPresenceResult result = pending.Dequeue();
                    Debug.Log("[OpenMaasoPresencePose] stage=" + stage + " root=" + receiver.ActiveAvatarRoot.position.ToString("F5") + " home=" + home.ToString("F5"));
                    receipts.Add(JsonUtility.ToJson(result));
                    if (result.requestId == "public-presence-cancel-enter")
                    {
                        if (result.ok || result.code != "cancelled")
                            throw new InvalidOperationException("Interrupted entry did not reject its old completion.");
                        cancelledEntryObserved = true;
                        continue;
                    }
                    if (stage == "missing-enter")
                    {
                        if (result.ok || result.code != "walk_unavailable")
                            throw new InvalidOperationException("Idle-only fixture did not reproduce walk_unavailable.");
                        missingWalkObserved = true;
                        animator.runtimeAnimatorController = realController;
                        animator.Rebind(); animator.Play("Idle");
                        Send("setLocalAvatarVisible", "{\"visible\":false}");
                        Phase("real-prepare", "real", "prepare");
                        continue;
                    }
                    if (!result.ok) throw new InvalidOperationException(stage + ":" + result.code);
                    switch (stage)
                    {
                        case "missing-prepare":
                            Send("setLocalAvatarVisible", "{\"visible\":true}");
                            Phase("missing-enter", "missing", "enter"); break;
                        case "real-prepare":
                            // The diagnostic Idle-only controller swap/rebind
                            // precedes this transaction. Capture its actual
                            // rendered prepared Home pose, like the receiver.
                            home = receiver.ActiveAvatarRoot.position;
                            Save("hidden-prepared.png");
                            Send("setLocalAvatarVisible", "{\"visible\":true}");
                            Phase("real-enter", "real", "enter"); break;
                        case "real-enter": stage = "settle"; settleFrames = 0; break;
                        case "resume-prepare": Phase("resume-restore", "resume", "restore"); break;
                        case "resume-restore":
                            AssertHomeVisible(); Phase("cancel-prepare", "cancel", "prepare"); break;
                        case "cancel-prepare":
                            Send("setLocalAvatarVisible", "{\"visible\":true}");
                            Phase("cancel-enter", "cancel", "enter"); break;
                        case "cancel-hold":
                            if (receiver.ActiveAvatarRoot.GetComponentsInChildren<Renderer>(true)
                                .Any(value => value.enabled && value.gameObject.activeInHierarchy && !value.forceRenderingOff))
                                throw new InvalidOperationException("Interrupted entry did not hold the actor hidden.");
                            Phase("cancel-restore", "cancel", "restore"); break;
                        case "cancel-restore":
                            stage = "cancel-settle"; finishAtFrame = Time.frameCount + 3;
                            recoverAtTime = Time.realtimeSinceStartup + .35f; break;
                    }
                }
            }
            catch (Exception error) { Debug.LogException(error); Stop(1); }
        }

        private static void Phase(string next, string transaction, string phase)
        {
            stage = next; phaseStarted = Time.realtimeSinceStartup;
            Send("transitionPresence", JsonUtility.ToJson(new AvatarPresenceCommand
            {
                requestId = "public-presence-" + next,
                transitionId = "public-presence-" + transaction,
                phase = phase, edge = "right", durationMs = 1565,
                doNotInterrupt = true, sequence = ++sequence,
                // Same duration + 5s deadline as UnityAvatarPresenceTransitions.
                expiresAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 6565,
            }));
        }

        private static Sample ReadSample()
        {
            Transform root = receiver.ActiveAvatarRoot;
            Vector3 left = root.InverseTransformPoint(animator.GetBoneTransform(HumanBodyBones.LeftFoot).position);
            Vector3 right = root.InverseTransformPoint(animator.GetBoneTransform(HumanBodyBones.RightFoot).position);
            return new Sample { root = root.position, leftFoot = left, rightFoot = right,
                stride = left.z - right.z, walkingState = animator.GetCurrentAnimatorStateInfo(0).IsName("standard_walk") };
        }

        private static void AssertHomeVisible()
        {
            // Hidden preparation cannot ground renderer bounds. The room owns
            // the small vertical sole-contact correction after reveal; Presence
            // must return the same horizontal Home rather than fight grounding.
            Vector3 delta = receiver.ActiveAvatarRoot.position - home;
            if (new Vector2(delta.x, delta.z).magnitude > .015f)
                throw new InvalidOperationException("Presence did not restore the prepared Home X/Z: expected=" + home.ToString("F5") + " actual=" + receiver.ActiveAvatarRoot.position.ToString("F5"));
            if (!receiver.ActiveAvatarRoot.GetComponentsInChildren<Renderer>(true)
                .Any(value => value.enabled && value.gameObject.activeInHierarchy && !value.forceRenderingOff))
                throw new InvalidOperationException("A success receipt left the actor hidden.");
            Type type = typeof(UnityAvatarCommandReceiver).Assembly.GetType("Maaso.Avatar.AvatarVisualBounds", true);
            var arguments = new object[] { receiver.ActiveAvatarRoot, new List<Renderer>(), default(Bounds), false };
            bool valid = (bool)type.GetMethod("TryGetCurrent", BindingFlags.Static | BindingFlags.Public).Invoke(null, arguments);
            Bounds bounds = (Bounds)arguments[2];
            if (!valid ||
                Mathf.Abs(bounds.min.y - (PersistentWorldMapController.GroundY - WorldAvatarGrounding.GroundContactInset)) > .015f)
                throw new InvalidOperationException("The visible Home actor did not finish grounded.");
        }

        private static void Finish()
        {
            if (!missingWalkObserved || !cancelledEntryObserved || samples.Count != 3 || !samples.Any(value => value.walkingState) ||
                samples.Max(value => value.stride) - samples.Min(value => value.stride) < .04f ||
                Vector3.Distance(samples[0].root, samples[^1].root) < .1f)
                throw new InvalidOperationException("Presence moved without an observable walk stride.");
            File.WriteAllText(Path.Combine(evidence, "presence-receipts.json"), JsonUtility.ToJson(new Evidence
            {
                unityVersion = Application.unityVersion,
                missingWalkFailureReproduced = missingWalkObserved,
                cancelledEntryCompletionRejected = cancelledEntryObserved,
                home = home, deliveredHome = receiver.ActiveAvatarRoot.position,
                samples = samples.ToArray(), receipts = receipts.ToArray(),
            }, true) + "\n");
            Debug.Log("[OpenMaasoPresence] VERIFIED missing-walk failure, rendered cold entry, repeat restore and interrupted-entry recovery.");
            Stop(0);
        }

        private static void Save(string name) => LoginDoorwayAssetBuilder.SaveFrame(camera, target, Path.Combine(evidence, name));
        private static void Send(string method, string json) => receiver.OnFlutterCommand(JsonUtility.ToJson(new Envelope { method = method, json = json }));
        private static void Stop(int code)
        {
            SessionState.SetBool(Session, false);
            EditorApplication.update -= Tick; Application.logMessageReceived -= ReadReceipt;
            if (animator != null && realController != null) animator.runtimeAnimatorController = realController;
            if (camera != null) camera.targetTexture = null;
            if (target != null) { target.Release(); Object.DestroyImmediate(target); }
            if (missingController != null) Object.DestroyImmediate(missingController);
            if (missingMachine != null) Object.DestroyImmediate(missingMachine);
            EditorApplication.Exit(code);
        }

        [Serializable] private sealed class Envelope { public string method, json; }
        [Serializable] private sealed class Sample { public Vector3 root, leftFoot, rightFoot; public float stride; public bool walkingState; }
        [Serializable] private sealed class Evidence
        {
            public string kind = "Actual Receiver/PlayMode after-frame evidence; not a phone capture";
            public string unityVersion; public bool missingWalkFailureReproduced, cancelledEntryCompletionRejected;
            public Vector3 home, deliveredHome; public Sample[] samples; public string[] receipts;
        }
    }
}
#endif
